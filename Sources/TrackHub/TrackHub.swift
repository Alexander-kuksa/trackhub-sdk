import Foundation
import CryptoKit

/// TrackHub iOS SDK — install reporting, AdServices attribution passthrough,
/// remote-controlled SKAN conversion values (Conversion Hub), app sessions
/// (DAU/WAU/MAU + retention) and custom events.
///
/// Usage:
/// ```swift
/// TrackHub.configure(
///     endpoint: URL(string: "https://postbacks.example.com")!,
///     ingestToken: "<app ingest token>",
///     userId: Apphud.userID()   // optional; a device id is generated if omitted
/// )
/// TrackHub.trackEvent("level_complete")
/// TrackHub.track("trial_converted", revenueCents: 999) // SKAN conversion value
/// ```
public enum TrackHub {
    /// SDK version reported to the platform for integration detection.
    public static let sdkVersion = "1.1.0"

    private static let queue = DispatchQueue(label: "com.trackhub.sdk")
    private static var config: Config?
    private static var schema: ConversionSchema?
    private static var debugLogging = false

    private static var sessionTracker: SessionTracker?
    private static var eventQueue: EventQueue?
    private static var globalCallbackParams: [String: Any] = [:]
    private static var globalPartnerParams: [String: Any] = [:]
    #if os(iOS)
    private static var lifecycleObserver: LifecycleObserver?
    #endif

    struct Config {
        let endpoint: URL
        let ingestToken: String
        var userId: String
        let sdkSecret: String?
    }

    private static let schemaCacheKey = "trackhub.cv_schema"
    private static let installSentKey = "trackhub.install_sent"
    private static let deviceIdKey = "trackhub.device_id"

    private static let iso8601 = ISO8601DateFormatter()

    // MARK: - Public API

    /// Call once on app launch. Reports the install (first launch only, including
    /// the AdServices attribution token), starts session tracking, refreshes the
    /// conversion value schema, and flushes any buffered offline reports.
    ///
    /// `userId` ties installs/sessions/events to the same user as your revenue
    /// source (e.g. Apphud). It is OPTIONAL — when omitted, a persistent device
    /// id is generated, so the SDK works with no Apphud at all. Set the real id
    /// later with `setUserId(_:)`.
    public static func configure(
        endpoint: URL,
        ingestToken: String,
        userId: String? = nil,
        sdkSecret: String? = nil,
        debug: Bool = false
    ) {
        // Plaintext HTTP would expose the ingest token in transit and let a
        // MITM poison the cached conversion value schema. localhost is the
        // only exception (local development).
        guard endpoint.scheme == "https"
            || endpoint.host == "localhost" || endpoint.host == "127.0.0.1"
        else {
            print("[TrackHub] refusing non-HTTPS endpoint \(endpoint) — SDK not configured")
            return
        }
        queue.async {
            let resolvedUserId = userId ?? resolveDeviceId()
            config = Config(endpoint: endpoint, ingestToken: ingestToken, userId: resolvedUserId, sdkSecret: sdkSecret)
            debugLogging = debug
            schema = loadCachedSchema()
            sessionTracker = sessionTracker ?? SessionTracker()
            eventQueue = eventQueue ?? EventQueue(maxItems: 1000, url: queueFileURL())
            SKANUpdater.registerForAttribution()
            reportInstallIfNeeded()
            refreshSchema()
            startSessionTracking()
            flush()
        }
    }

    /// Update the user id after configure (e.g. once Apphud resolves it).
    public static func setUserId(_ userId: String) {
        queue.async { config?.userId = userId }
    }

    /// A global callback parameter attached to every subsequent event.
    public static func setGlobalCallbackParameter(_ value: Any, forKey key: String) {
        queue.async { globalCallbackParams[key] = value }
    }

    /// A global partner parameter attached to every subsequent event.
    public static func setGlobalPartnerParameter(_ value: Any, forKey key: String) {
        queue.async { globalPartnerParams[key] = value }
    }

    /// Tracks a custom event: sends it to TrackHub analytics AND, when the active
    /// schema has a matching rule, applies the SKAN conversion value. Revenue in
    /// minor units (cents); revenue here is informational in analytics — the
    /// authoritative ROAS figure comes from verified purchases / Apphud.
    public static func trackEvent(
        _ name: String,
        revenueCents: Int? = nil,
        currency: String? = nil,
        transactionId: String? = nil,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:]
    ) {
        queue.async {
            guard let config else {
                log("trackEvent(\(name)) before configure — skipped")
                return
            }
            var body: [String: Any] = [
                "client_event_id": UUID().uuidString,
                "event_name": name,
                "user_id": config.userId,
                "occurred_at": iso8601.string(from: Date()),
            ]
            let cb = globalCallbackParams.merging(callbackParams) { _, new in new }
            let pp = globalPartnerParams.merging(partnerParams) { _, new in new }
            if !cb.isEmpty { body["callback_params"] = cb }
            if !pp.isEmpty { body["partner_params"] = pp }
            if let revenueCents { body["revenue_cents"] = revenueCents }
            if let currency { body["currency"] = currency }
            if let transactionId { body["transaction_id"] = transactionId }
            send(path: "sdk/track", body: body)
        }
        // also drive the on-device SKAN conversion value (no-op if no rule)
        track(name, revenueCents: revenueCents)
    }

    /// Applies the SKAN conversion value mapped by the active schema (fine +
    /// coarse + lockWindow) for `event`. Does NOT send analytics — use
    /// `trackEvent` for that. Revenue in minor units.
    public static func track(_ event: String, revenueCents: Int? = nil) {
        queue.async {
            guard let schema else {
                log("track(\(event)) before schema is available — skipped")
                return
            }
            guard let update = ConversionEncoder.encode(
                schema: schema, event: event, revenueCents: revenueCents
            ) else {
                log("event \(event) has no rule in schema v\(schema.schemaVersion)")
                return
            }
            log("event \(event) → fine \(update.fine), coarse \(update.coarse ?? "—"), lock \(update.lockWindow)")
            SKANUpdater.apply(update)
        }
    }

    /// Forces a schema refresh (normally done automatically on configure).
    public static func refreshConversionSchema() {
        queue.async { refreshSchema() }
    }

    // MARK: - Sessions

    private static func startSessionTracking() {
        #if os(iOS)
        if lifecycleObserver == nil {
            lifecycleObserver = LifecycleObserver(
                onForeground: { queue.async { handleForeground() } },
                onBackground: { queue.async { handleBackground() } }
            )
        }
        handleForeground() // the launch foreground
        #endif
    }

    // Must run on `queue`. Reports a new session if the foreground started one.
    private static func handleForeground() {
        guard let config, let tracker = sessionTracker else { return }
        guard let started = tracker.foreground() else { return }
        var body: [String: Any] = [
            "user_id": config.userId,
            "session_uid": started.sessionUid,
            "session_num": started.sessionNum,
            "started_at": iso8601.string(from: started.startedAt),
        ]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["app_version"] = version
        }
        body["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        send(path: "sdk/session", body: body)
    }

    private static func handleBackground() {
        sessionTracker?.background()
    }

    // MARK: - Install reporting

    private static func reportInstallIfNeeded() {
        guard let config else { return }
        guard !UserDefaults.standard.bool(forKey: installSentKey) else { return }

        // sdk_* fields go inside the signed body so the HMAC authenticates the
        // integration marker too (no spoofable header).
        var body: [String: Any] = [
            "user_id": config.userId,
            "sdk_name": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
        ]
        #if os(iOS)
        body["platform"] = "ios"
        #endif
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["app_version"] = version
        }
        body["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        body["occurred_at"] = iso8601.string(from: Date())
        if let token = SKANUpdater.attributionToken() {
            body["adservices_token"] = token
        }

        post(path: "install", body: body) { success in
            if success {
                UserDefaults.standard.set(true, forKey: installSentKey)
                log("install reported")
            } else {
                log("install report failed — will retry on next launch")
            }
        }
    }

    // MARK: - Schema fetch & cache

    private static func refreshSchema() {
        guard let config else { return }
        let url = config.endpoint
            .appendingPathComponent("ingest")
            .appendingPathComponent(config.ingestToken)
            .appendingPathComponent("cv-schema")

        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let fetched = try? JSONDecoder().decode(ConversionSchema.self, from: data)
            else {
                log("schema refresh failed — using cached version")
                return
            }
            queue.async {
                schema = fetched
                UserDefaults.standard.set(data, forKey: schemaCacheKey)
                log("schema v\(fetched.schemaVersion) active (\(fetched.rules.count) rules)")
            }
        }.resume()
    }

    private static func loadCachedSchema() -> ConversionSchema? {
        guard let data = UserDefaults.standard.data(forKey: schemaCacheKey) else { return nil }
        return try? JSONDecoder().decode(ConversionSchema.self, from: data)
    }

    // MARK: - Offline buffer

    private static func queueFileURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("trackhub_queue.json")
    }

    // Send a report; on failure (offline / 5xx) buffer it for retry next launch.
    private static func send(path: String, body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        postRaw(path: path, bodyData: data) { ok in
            if !ok {
                queue.async { eventQueue?.enqueue(PendingReport(path: path, body: data)) }
            }
        }
    }

    // Drain buffered reports; each is signed FRESH at send time so a stale
    // timestamp never rejects buffered traffic. Successful sends pop; failures
    // stay for the next flush.
    private static func flush() {
        guard let q = eventQueue else { return }
        for report in q.items {
            postRaw(path: report.path, bodyData: report.body) { ok in
                if ok { queue.async { eventQueue?.remove(id: report.id) } }
            }
        }
    }

    // MARK: - Device id

    private static func resolveDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let id = "dev_" + UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    // MARK: - Networking

    private static func post(path: String, body: [String: Any], completion: @escaping (Bool) -> Void) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        postRaw(path: path, bodyData: data, completion: completion)
    }

    // Signs `bodyData` with a FRESH timestamp at call time (so buffered reports
    // re-signed at flush stay within the server's ±5min replay window).
    private static func postRaw(path: String, bodyData: Data, completion: @escaping (Bool) -> Void) {
        guard let config else { return completion(false) }
        let url = config.endpoint
            .appendingPathComponent("ingest")
            .appendingPathComponent(config.ingestToken)
            .appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // SDK Signature: HMAC-SHA256 over "<timestamp>.<token>.<body>" so the
        // server can tell a real SDK report from a replayed bearer token.
        if let secret = config.sdkSecret, !secret.isEmpty {
            let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
            let message = "\(timestamp).\(config.ingestToken).\(String(data: bodyData, encoding: .utf8) ?? "")"
            let mac = HMAC<SHA256>.authenticationCode(
                for: Data(message.utf8),
                using: SymmetricKey(data: Data(secret.utf8))
            )
            let signature = mac.map { String(format: "%02x", $0) }.joined()
            request.setValue(timestamp, forHTTPHeaderField: "X-TrackHub-Timestamp")
            request.setValue(signature, forHTTPHeaderField: "X-TrackHub-Signature")
        }

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion(ok)
        }.resume()
    }

    static func log(_ message: String) {
        if debugLogging { print("[TrackHub] \(message)") }
    }
}
