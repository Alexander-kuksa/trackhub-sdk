import Foundation

/// A new session that began on foreground — reported to /sdk/session.
public struct SessionStart: Equatable {
    public let sessionUid: String
    public let sessionNum: Int
    public let startedAt: Date
}

/// Pure session state machine (Adjust-style), platform-independent so it runs in
/// the macOS parity tests. A new session starts on first foreground, or when the
/// gap since the last activity exceeds `timeout` (default 60s) — brief
/// backgrounding coalesces. The session number is monotonic per install.
public final class SessionTracker {
    private let timeout: TimeInterval
    private let defaults: UserDefaults
    private let uuid: () -> String
    private let seqKey = "trackhub.session_seq"
    private let lastActivityKey = "trackhub.session_last_activity"

    // public for the parity-test target (mirrors ConversionEncoder).
    public init(timeout: TimeInterval = 60, defaults: UserDefaults = .standard, uuid: @escaping () -> String = { UUID().uuidString }) {
        self.timeout = timeout
        self.defaults = defaults
        self.uuid = uuid
    }

    /// On foreground: returns a `SessionStart` when a NEW session began, else nil.
    public func foreground(at now: Date = Date()) -> SessionStart? {
        let last = defaults.object(forKey: lastActivityKey) as? Date
        let isNew = last == nil || now.timeIntervalSince(last!) > timeout
        defaults.set(now, forKey: lastActivityKey)
        guard isNew else { return nil }
        let seq = defaults.integer(forKey: seqKey) + 1
        defaults.set(seq, forKey: seqKey)
        return SessionStart(sessionUid: uuid(), sessionNum: seq, startedAt: now)
    }

    /// On background: extends the activity window so a quick return coalesces.
    public func background(at now: Date = Date()) {
        defaults.set(now, forKey: lastActivityKey)
    }
}
