import Foundation

/// A new session that began on foreground — reported to /sdk/session.
public struct SessionStart: Equatable {
    public let sessionUid: String
    public let sessionNum: Int
    public let startedAt: Date
}

/// Pure session state machine (Adjust-style), platform-independent so it runs in
/// the macOS parity tests. A new session begins on the first foreground, or when
/// the gap since the last activity (foreground or background) exceeds `timeout`
/// (default 60s) — brief backgrounding coalesces into one session. The session
/// number is monotonic per install, persisted in UserDefaults.
public final class SessionTracker {
    private let timeout: TimeInterval
    private let defaults: UserDefaults
    private let uuid: () -> String

    private let seqKey = "trackhub.session_seq"
    private let lastActivityKey = "trackhub.session_last_activity"

    // public for the parity-test target (mirrors ConversionEncoder); not part of
    // the everyday SDK surface.
    public init(
        timeout: TimeInterval = 60,
        defaults: UserDefaults = .standard,
        uuid: @escaping () -> String = { UUID().uuidString }
    ) {
        self.timeout = timeout
        self.defaults = defaults
        self.uuid = uuid
    }

    /// Call when the app foregrounds. Returns a `SessionStart` when a NEW session
    /// began, or nil when this foreground coalesces into the current session.
    public func foreground(at now: Date = Date()) -> SessionStart? {
        let last = defaults.object(forKey: lastActivityKey) as? Date
        let isNew = last == nil || now.timeIntervalSince(last!) > timeout
        defaults.set(now, forKey: lastActivityKey)
        guard isNew else { return nil }
        let seq = defaults.integer(forKey: seqKey) + 1
        defaults.set(seq, forKey: seqKey)
        return SessionStart(sessionUid: uuid(), sessionNum: seq, startedAt: now)
    }

    /// Call when the app backgrounds — extends the activity window so a quick
    /// return does not start a fresh session.
    public func background(at now: Date = Date()) {
        defaults.set(now, forKey: lastActivityKey)
    }

    /// Wipe session state (used by GDPR forget-me in a later phase).
    public func reset() {
        defaults.removeObject(forKey: seqKey)
        defaults.removeObject(forKey: lastActivityKey)
    }
}
