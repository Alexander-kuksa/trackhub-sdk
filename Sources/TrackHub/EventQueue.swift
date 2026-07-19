import Foundation

/// A buffered report awaiting delivery — path (relative to /ingest/{token}/) and
/// the exact JSON body. The body is signed FRESH at send time, so a report
/// buffered for hours still authenticates.
@_spi(Testing) public struct PendingReport: Codable, Equatable {
    public let id: String
    public let path: String
    public let body: Data
    public let createdAt: Date

    public init(id: String = UUID().uuidString, path: String, body: Data, createdAt: Date = Date()) {
        self.id = id
        self.path = path
        self.body = body
        self.createdAt = createdAt
    }
}

/// Bounded, disk-persisted FIFO offline buffer. Failed sends (offline / 5xx) are
/// retained and retried next launch; 2xx/4xx pop. At the cap the OLDEST reports
/// are evicted. Platform-independent so it runs in the macOS parity tests.
@_spi(Testing) public final class EventQueue {
    private let maxItems: Int
    private let url: URL
    public private(set) var items: [PendingReport]

    public init(maxItems: Int = 1000, url: URL) {
        self.maxItems = maxItems
        self.url = url
        self.items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PendingReport].self, from: $0) } ?? []
    }

    public var count: Int { items.count }

    public func enqueue(_ report: PendingReport) {
        items.append(report)
        if items.count > maxItems { items.removeFirst(items.count - maxItems) } // evict oldest
        persist()
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
        #if os(iOS)
        // Buffered event parameters can be user data. Make their at-rest
        // protection explicit instead of relying on the embedding app's
        // default file-protection class.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
