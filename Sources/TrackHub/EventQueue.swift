import Foundation

/// A buffered report awaiting delivery — path (relative to /ingest/{token}/) and
/// the exact JSON body. The body is signed FRESH at send time, so a report
/// buffered for hours still authenticates.
@_spi(Testing) public struct PendingReport: Codable, Equatable {
    public let id: String
    public let path: String
    public let body: Data
    public let createdAt: Date
    public let kind: String?
    public let dedupeKey: String?
    public let attempts: Int
    public let nextAttemptAt: Date

    public init(
        id: String = UUID().uuidString,
        path: String,
        body: Data,
        createdAt: Date = Date(),
        kind: String? = nil,
        dedupeKey: String? = nil,
        attempts: Int = 0,
        nextAttemptAt: Date = .distantPast
    ) {
        self.id = id
        self.path = path
        self.body = body
        self.createdAt = createdAt
        self.kind = kind
        self.dedupeKey = dedupeKey
        self.attempts = max(0, attempts)
        self.nextAttemptAt = nextAttemptAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, body, createdAt, kind, dedupeKey, attempts, nextAttemptAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        body = try values.decode(Data.self, forKey: .body)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        kind = try values.decodeIfPresent(String.self, forKey: .kind)
        dedupeKey = try values.decodeIfPresent(String.self, forKey: .dedupeKey)
        attempts = max(0, try values.decodeIfPresent(Int.self, forKey: .attempts) ?? 0)
        nextAttemptAt = try values.decodeIfPresent(Date.self, forKey: .nextAttemptAt) ?? .distantPast
    }
}

/// Bounded, disk-persisted FIFO offline buffer. Every report is written before
/// network delivery starts. Limits apply both to item count and encoded bytes,
/// so hostile or accidental event parameters cannot grow the host app's cache
/// without bound.
@_spi(Testing) public final class EventQueue {
    public static let defaultMaxItems = 1000
    public static let defaultMaxBytes = 4 * 1024 * 1024
    public static let defaultMaxItemBytes = 64 * 1024

    private let maxItems: Int
    private let maxBytes: Int
    private let maxItemBytes: Int
    private let url: URL
    private var storageNeedsReload: Bool
    /// Set only when the latest durable mutation failed. Capacity eviction and
    /// payload rejection are expected bounded-buffer outcomes, not storage
    /// failures. TrackHub uses this distinction to open its fail-silent circuit
    /// instead of repeatedly touching unhealthy storage.
    public private(set) var storageFailure: Bool
    public private(set) var items: [PendingReport]

    public init(
        maxItems: Int = EventQueue.defaultMaxItems,
        maxBytes: Int = EventQueue.defaultMaxBytes,
        maxItemBytes: Int = EventQueue.defaultMaxItemBytes,
        url: URL
    ) {
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(1, maxBytes)
        self.maxItemBytes = max(1, min(maxItemBytes, maxBytes))
        self.url = url
        self.storageNeedsReload = false
        self.storageFailure = false
        self.items = []

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize > maxBytes * 2 {
            quarantineStorage()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            // A protected file can be temporarily unreadable before the first
            // device unlock. Do not overwrite a queue we have not loaded.
            storageNeedsReload = true
            return
        }
        guard let decoded = try? JSONDecoder().decode([PendingReport].self, from: data) else {
            quarantineStorage()
            return
        }
        items = decoded
        let loaded = items
        trimToLimits()
        if loaded != items { _ = persist() }
    }

    public var count: Int { items.count }

    /// Preserve FIFO delivery after the one-shot install anchor. ATT/ODM waits
    /// can buffer a session before the install body is finalized, and an
    /// upgraded legacy queue can begin with identity traffic. The server must
    /// see the installation before either, so an undelivered production install
    /// always goes first; all remaining reports keep their original order.
    @_spi(Testing) public var nextForDelivery: PendingReport? {
        items.first(where: { $0.kind == "production_install" }) ?? items.first
    }

    /// Returns the accepted report id, or nil when serialization/storage limits
    /// prevent acceptance. Before first unlock, iOS protected storage can be
    /// temporarily unreadable; new reports remain in memory and are merged
    /// with the disk queue as soon as protection becomes available.
    @discardableResult
    public func enqueue(_ report: PendingReport) -> String? {
        guard report.body.count <= maxItemBytes else { return nil }
        let storageReady = reloadStorageIfNeeded()
        let previous = items
        var stored = report
        if let key = report.dedupeKey,
           let index = items.firstIndex(where: { $0.dedupeKey == key }) {
            let existing = items[index]
            stored = PendingReport(
                id: existing.id,
                path: report.path,
                body: report.body,
                createdAt: existing.createdAt,
                kind: report.kind,
                dedupeKey: key
            )
            items[index] = stored
        } else {
            items.append(stored)
        }
        trimToLimits()
        guard items.contains(where: { $0.id == stored.id }) else {
            items = previous
            return nil
        }
        if storageReady, !persist() {
            items = previous
            return nil
        }
        return stored.id
    }

    /// Reloads and merges protected disk state before network delivery. A
    /// caller should retry later when this returns false.
    public func prepareForDelivery() -> Bool {
        reloadStorageIfNeeded()
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        let previousCount = items.count
        items.removeAll { $0.id == id }
        guard items.count != previousCount else { return false }
        // Keep the delivered report out of this process even when protected
        // storage is momentarily unavailable. Its stable event/install id lets
        // the server deduplicate a possible replay after the next launch.
        return persist()
    }

    @discardableResult
    public func markRetry(id: String, attempts: Int, nextAttemptAt: Date) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let previous = items[index]
        items[index] = PendingReport(
            id: previous.id,
            path: previous.path,
            body: previous.body,
            createdAt: previous.createdAt,
            kind: previous.kind,
            dedupeKey: previous.dedupeKey,
            attempts: attempts,
            nextAttemptAt: nextAttemptAt
        )
        guard persist() else {
            items[index] = previous
            return false
        }
        return true
    }

    @discardableResult
    public func removeAll() -> Bool {
        let previous = items
        let previouslyNeededReload = storageNeedsReload
        items.removeAll()
        storageNeedsReload = false
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            items = previous
            storageNeedsReload = previouslyNeededReload
            return false
        }
        return true
    }

    private func trimToLimits() {
        while items.count > maxItems {
            let index = evictionIndex()
            items.remove(at: index)
        }
        var sizes = items.map { (try? JSONEncoder().encode($0).count) ?? maxBytes + 1 }
        var total = 2 + sizes.reduce(0, +) + max(0, items.count - 1)
        while total > maxBytes, !items.isEmpty {
            let index = evictionIndex()
            total -= sizes[index]
            if items.count > 1 { total -= 1 } // one JSON-array comma
            items.remove(at: index)
            sizes.remove(at: index)
        }
    }

    private func evictionIndex() -> Int {
        // Install and transaction context are one-shot attribution anchors.
        // Evict normal analytics first; protected anchors still remain bounded
        // when the queue contains nothing else.
        items.firstIndex {
            $0.kind != "production_install" && $0.kind != "transaction_context"
        } ?? 0
    }

    private func reloadStorageIfNeeded() -> Bool {
        guard storageNeedsReload else { return true }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let decoded = try? JSONDecoder().decode([PendingReport].self, from: data) {
                let deferred = items
                items = decoded
                for report in deferred {
                    if let index = items.firstIndex(where: {
                        $0.id == report.id || (
                            report.dedupeKey != nil && $0.dedupeKey == report.dedupeKey
                        )
                    }) {
                        items[index] = report
                    } else {
                        items.append(report)
                    }
                }
                storageNeedsReload = false
                let loaded = items
                trimToLimits()
                return deferred.isEmpty && loaded == items ? true : persist()
            }
            quarantineStorage()
            storageNeedsReload = false
            trimToLimits()
            return persist()
        } catch {
            return false
        }
    }

    private func quarantineStorage() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let quarantineURL = url.appendingPathExtension(
            "corrupt-\(Int(Date().timeIntervalSince1970 * 1_000))"
        )
        try? FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    @discardableResult
    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(items), data.count <= maxBytes else {
            storageFailure = true
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            #if os(iOS)
            // Buffered event parameters can be user data. Make their at-rest
            // protection explicit instead of relying on the embedding app's
            // default file-protection class.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            #endif
            storageFailure = false
            return true
        } catch {
            storageFailure = true
            return false
        }
    }
}
