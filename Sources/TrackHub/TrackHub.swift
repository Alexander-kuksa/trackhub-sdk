import Foundation
import CryptoKit

/// TrackHub iOS SDK — installs (+ AdServices ASA and Google gbraid/wbraid
/// attribution), SKAN conversion values (Conversion Hub), app sessions
/// (DAU/WAU/MAU + retention) and custom events.
///
/// ```swift
/// TrackHub.configure(endpoint: URL(string: "https://postbacks.example.com")!,
///                    ingestToken: "<token>", userId: Apphud.userID())
/// TrackHub.trackEvent("level_complete")
/// ```
public enum TrackHub {
    /// SDK version reported to the platform for integration detection.
    public static let sdkVersion = "1.2.0"

    private static let queue = DispatchQueue(label: "com.trackhub.sdk")
    private static var config: Config?
    private static var schema: ConversionSchema?
    private static var debugLogging = false
    private static var sessionTracker: SessionTracker?
    private static var eventQueue: EventQueue?
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
    private static let gbraidKey = "trackhub.gbraid"
    private static let wbraidKey = "trackhub.wbraid"
    private static let iso8601 = ISO8601DateFormatter()

    // MARK: - Public API

    /// Call once on launch. Reports the install (first launch only, with the
    /// AdServices token), starts session tracking, refreshes the schema and
    /// flushes buffered offline reports. `userId` is OPTIONAL — a persistent
    /// device id is generated when omitted, so the SDK needs no Apphud; set the
    /// real id later with `setUserId`.
    public static func configure(
        endpoint: URL,
        ingestToken: String,
        userId: String? = nil,
        sdkSecret: String? = nil,
        debug: Bool = false
    ) {
        // Refuse plaintext HTTP (token in transit + MITM schema poisoning); allow localhost for dev.
        guard endpoint.scheme == "https" || endpoint.host == "localhost" || endpoint.host == "127.0.0.1" else {
            print("[TrackHub] refusing non-HTTPS endpoint \(endpoint) — SDK not configured")
            return
        }
        queue.async {
            config = Config(endpoint: endpoint, ingestToken: ingestToken, userId: userId ?? resolveDeviceId(), sdkSecret: sdkSecret)
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

    /// Update the user id after configure (e.g. once the billing SDK resolves it).
    public static func setUserId(_ userId: String) {
        queue.async { config?.userId = userId }
    }

    /// Record a Google click identifier captured from the ad click's deep link:
    /// `gbraid` (iOS app click) or `wbraid` (web-to-app). TrackHub attaches it to
    /// the one-shot install report so the resulting purchase can be sent back to
    /// Google Ads for that click — letting Smart Bidding optimize iOS App-campaign
    /// traffic that carries a click id. Call this BEFORE `configure(...)` (the
    /// install report is sent once, on first launch). Pure SKAdNetwork installs
    /// carry no click id and stay SKAN-aggregate (Apple's privacy model).
    public static func setGoogleClickId(gbraid: String? = nil, wbraid: String? = nil) {
        if let g = gbraid, !g.isEmpty { UserDefaults.standard.set(g, forKey: gbraidKey) }
        if let w = wbraid, !w.isEmpty { UserDefaults.standard.set(w, forKey: wbraidKey) }
    }

    /// Convenience over `setGoogleClickId`: extracts `gbraid` / `wbraid` from a
    /// deep-link / universal-link URL's query and stores them. Returns true if a
    /// Google click id was found. Call from your URL handler and, on a cold launch
    /// from a click, from the launch URL — before `configure(...)`.
    @discardableResult
    public static func handleDeepLink(_ url: URL) -> Bool {
        let ids = parseGoogleClickIds(from: url)
        guard ids.gbraid != nil || ids.wbraid != nil else { return false }
        setGoogleClickId(gbraid: ids.gbraid, wbraid: ids.wbraid)
        return true
    }

    /// Pure URL → (gbraid, wbraid) extraction (empty values treated as absent).
    @_spi(Testing) public static func parseGoogleClickIds(from url: URL) -> (gbraid: String?, wbraid: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let v = items.first { $0.name == name }?.value
            return (v?.isEmpty == false) ? v : nil
        }
        return (value("gbraid"), value("wbraid"))
    }

    /// Tracks a custom event → TrackHub analytics, and applies the SKAN
    /// conversion value when the active schema has a matching rule. Revenue (cents)
    /// is informational in analytics — authoritative ROAS comes from verified
    /// purchases / Apphud.
    public static func trackEvent(
        _ name: String,
        revenueCents: Int? = nil,
        currency: String? = nil,
        transactionId: String? = nil,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:]
    ) {
        queue.async {
            guard let config else { return log("trackEvent(\(name)) before configure — skipped") }
            var body: [String: Any] = [
                "client_event_id": UUID().uuidString,
                "event_name": name,
                "user_id": config.userId,
                "occurred_at": iso8601.string(from: Date()),
            ]
            if !callbackParams.isEmpty { body["callback_params"] = callbackParams }
            if !partnerParams.isEmpty { body["partner_params"] = partnerParams }
            if let revenueCents { body["revenue_cents"] = revenueCents }
            if let currency { body["currency"] = currency }
            if let transactionId { body["transaction_id"] = transactionId }
            send(path: "sdk/track", body: body)
        }
        track(name, revenueCents: revenueCents) // also drive the on-device SKAN value
    }

    /// Applies only the SKAN conversion value for `event` (no analytics — use
    /// `trackEvent` for that). Revenue in minor units.
    public static func track(_ event: String, revenueCents: Int? = nil) {
        queue.async {
            guard let schema else { return log("track(\(event)) before schema is available — skipped") }
            guard let update = ConversionEncoder.encode(schema: schema, event: event, revenueCents: revenueCents) else {
                return log("event \(event) has no rule in schema v\(schema.schemaVersion)")
            }
            log("event \(event) → fine \(update.fine), coarse \(update.coarse ?? "—"), lock \(update.lockWindow)")
            SKANUpdater.apply(update)
        }
    }

    /// Forces a schema refresh (normally automatic on configure).
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

    // On `queue`. Reports a new session if this foreground started one.
    private static func handleForeground() {
        guard let config, let started = sessionTracker?.foreground() else { return }
        var body: [String: Any] = [
            "user_id": config.userId,
            "session_uid": started.sessionUid,
            "session_num": started.sessionNum,
            "started_at": iso8601.string(from: started.startedAt),
        ]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = v }
        body["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        send(path: "sdk/session", body: body)
    }

    private static func handleBackground() { sessionTracker?.background() }

    // MARK: - Install

    private static func reportInstallIfNeeded() {
        guard let config else { return }
        guard !UserDefaults.standard.bool(forKey: installSentKey) else { return }
        // sdk_* go inside the signed body so the HMAC authenticates the integration marker too.
        var body: [String: Any] = [
            "user_id": config.userId,
            "sdk_name": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
        ]
        #if os(iOS)
        body["platform"] = "ios"
        #endif
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = v }
        body["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        body["occurred_at"] = iso8601.string(from: Date())
        if let token = SKANUpdater.attributionToken() { body["adservices_token"] = token }
        // Google click ids captured from a deep link (set via setGoogleClickId /
        // handleDeepLink before configure) — the iOS path for user-level Google
        // attribution + conversion return.
        if let g = UserDefaults.standard.string(forKey: gbraidKey) { body["gbraid"] = g }
        if let w = UserDefaults.standard.string(forKey: wbraidKey) { body["wbraid"] = w }

        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        postRaw(path: "install", bodyData: data) { ok in
            if ok { UserDefaults.standard.set(true, forKey: installSentKey); log("install reported") }
            else { log("install report failed — will retry on next launch") }
        }
    }

    // MARK: - Schema

    private static func refreshSchema() {
        guard let config else { return }
        let url = config.endpoint.appendingPathComponent("ingest").appendingPathComponent(config.ingestToken).appendingPathComponent("cv-schema")
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let fetched = try? JSONDecoder().decode(ConversionSchema.self, from: data) else {
                return log("schema refresh failed — using cached version")
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

    // MARK: - Offline buffer + networking

    private static func queueFileURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("trackhub_queue.json")
    }

    // Send a report; on failure (offline / 5xx) buffer it for retry next launch.
    private static func send(path: String, body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        postRaw(path: path, bodyData: data) { ok in
            if !ok { queue.async { eventQueue?.enqueue(PendingReport(path: path, body: data)) } }
        }
    }

    // Drain buffered reports; each is signed FRESH at send time so a stale
    // timestamp never rejects buffered traffic. 2xx pops; failures stay.
    private static func flush() {
        guard let q = eventQueue else { return }
        for report in q.items {
            postRaw(path: report.path, bodyData: report.body) { ok in
                if ok { queue.async { eventQueue?.remove(id: report.id) } }
            }
        }
    }

    private static func resolveDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let id = "dev_" + UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    // Signs `bodyData` with a FRESH timestamp at call time (so reports re-sent
    // from the offline buffer stay within the server's ±5min replay window).
    private static func postRaw(path: String, bodyData: Data, completion: @escaping (Bool) -> Void) {
        guard let config else { return completion(false) }
        let url = config.endpoint.appendingPathComponent("ingest").appendingPathComponent(config.ingestToken).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        if let secret = config.sdkSecret, !secret.isEmpty {
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            let message = "\(ts).\(config.ingestToken).\(String(data: bodyData, encoding: .utf8) ?? "")"
            let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            request.setValue(ts, forHTTPHeaderField: "X-TrackHub-Timestamp")
            request.setValue(mac.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-TrackHub-Signature")
        }
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
        }.resume()
    }

    static func log(_ message: String) {
        if debugLogging { print("[TrackHub] \(message)") }
    }
}
