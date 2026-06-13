import Foundation
import CryptoKit

/// TrackHub iOS SDK — install reporting, AdServices attribution passthrough
/// and remote-controlled SKAN conversion values (Conversion Hub).
///
/// Usage:
/// ```swift
/// TrackHub.configure(
///     endpoint: URL(string: "https://postbacks.example.com")!,
///     ingestToken: "<app ingest token>",
///     userId: Apphud.userID()
/// )
/// TrackHub.track("trial_started")
/// TrackHub.track("trial_converted", revenueCents: 999)
/// ```
public enum TrackHub {
    /// SDK version reported to the platform for integration detection.
    public static let sdkVersion = "1.0.0"

    private static let queue = DispatchQueue(label: "com.trackhub.sdk")
    private static var config: Config?
    private static var schema: ConversionSchema?
    private static var debugLogging = false

    struct Config {
        let endpoint: URL
        let ingestToken: String
        let userId: String
        let sdkSecret: String?
    }

    private static let schemaCacheKey = "trackhub.cv_schema"
    private static let installSentKey = "trackhub.install_sent"

    // MARK: - Public API

    /// Call once on app launch. Reports the install (first launch only,
    /// including the AdServices attribution token) and refreshes the
    /// conversion value schema from the platform.
    public static func configure(
        endpoint: URL,
        ingestToken: String,
        userId: String,
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
            config = Config(endpoint: endpoint, ingestToken: ingestToken, userId: userId, sdkSecret: sdkSecret)
            debugLogging = debug
            schema = loadCachedSchema()
            SKANUpdater.registerForAttribution()
            reportInstallIfNeeded()
            refreshSchema()
        }
    }

    /// Tracks an event: applies the SKAN conversion value mapped by the
    /// active schema (fine + coarse + lockWindow). Revenue in minor units.
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
        body["occurred_at"] = ISO8601DateFormatter().string(from: Date())
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

    // MARK: - Networking

    private static func post(path: String, body: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let config else { return completion(false) }
        let url = config.endpoint
            .appendingPathComponent("ingest")
            .appendingPathComponent(config.ingestToken)
            .appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        request.httpBody = bodyData

        // SDK Signature: HMAC-SHA256 over "<timestamp>.<token>.<body>" so the
        // server can tell a real SDK report from a replayed bearer token
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
