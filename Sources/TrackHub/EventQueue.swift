import Foundation

/// A buffered report awaiting delivery — the path (relative to /ingest/{token}/)
/// and the exact JSON body. The body is signed FRESH at send time, so a report
/// buffered for hours still authenticates (the SDK Signature timestamp is
/// generated at flush, not when the event was created).
public struct PendingReport: Codable, Equatable {
    public let id: String
    public let path: String // e.g. "sdk/session" | "sdk/track"
    public let body: Data
    public let createdAt: Date

    public init(id: String = UUID().uuidString, path: String, body: Data, createdAt: Date = Date()) {
        self.id = id
        self.path = path
        self.body = body
        self.createdAt = createdAt
    }
}

/// Bounded, disk-persisted FIFO offline buffer. Reports that fail to send (no
/// network / 5xx) are retained and retried on the next launch; 2xx and 4xx pop.
/// At the cap the OLDEST reports are evicted (engagement data is best-effort and
/// the server dedups retries, so dropping the tail is acceptable).
/// Platform-independent (FileManager) so it runs in the macOS parity tests.
public final class EventQueue {
    private let maxItems: Int
    private let url: URL
    public private(set) var items: [PendingReport]

    public init(maxItems: Int = 1000, url: URL) {
        self.maxItems = maxItems
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([PendingReport].self, from: data) {
            self.items = decoded
        } else {
            self.items = []
        }
    }

    public var count: Int { items.count }

    public func enqueue(_ report: PendingReport) {
        items.append(report)
        if items.count > maxItems {
            items.removeFirst(items.count - maxItems) // evict oldest (FIFO)
        }
        persist()
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
