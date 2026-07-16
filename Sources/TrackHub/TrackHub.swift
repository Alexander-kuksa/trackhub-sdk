import Foundation
import CryptoKit
#if canImport(StoreKit)
import StoreKit
#endif
#if os(iOS)
import UIKit
#endif

/// TrackHub iOS SDK — installs (+ Google gclid/gbraid attribution), SKAN +
/// AdAttributionKit conversion values (Conversion Hub), app sessions
/// (DAU/WAU/MAU + retention) and custom events.
///
/// ```swift
/// TrackHub.configure(endpoint: URL(string: "https://postbacks.example.com")!,
///                    ingestToken: "<token>", userId: Apphud.userID())
/// TrackHub.trackEvent("level_complete")
/// ```
public enum AdAttributionConversionTarget: Sendable, Equatable {
    case all
    case install
    case reengagement
}

/// Adapter installed by the host app after Apphud starts. TrackHub has no hard
/// dependency on ApphudSDK: pass `data` to Apphud's `.custom` attribution
/// provider and call `completion(true)` only when Apphud acknowledges it.
public typealias ApphudAttributionHandler = (
    _ data: [String: String],
    _ completion: @escaping (Bool) -> Void
) -> Void

public enum TrackHub {
    /// SDK version reported to the platform for integration detection.
    public static let sdkVersion = "1.6.1"

    private static let queue = DispatchQueue(label: "com.trackhub.sdk")
    private static var config: Config?
    private static var schema: ConversionSchema?
    private static var debugLogging = false
    private static var sessionTracker: SessionTracker?
    private static var eventQueue: EventQueue?
    private static var apphudAttributionFetchInFlight = false
    #if os(iOS)
    private static var lifecycleObserver: LifecycleObserver?
    #endif

    struct Config {
        let endpoint: URL
        let ingestToken: String
        var userId: String
        let sdkSecret: String?
        let integrationTestToken: String?
        let legacyAsaAttributionEnabled: Bool
        let apphudAttributionHandler: ApphudAttributionHandler?
    }

    private static let schemaCacheKey = "trackhub.cv_schema"
    private static let installSentKey = "trackhub.install_sent"
    private static let firstOpenAtKey = "trackhub.first_open_at"
    private static let deviceIdKey = "trackhub.device_id"
    private static let gclidKey = "trackhub.gclid"
    private static let gbraidKey = "trackhub.gbraid"
    private static let wbraidKey = "trackhub.wbraid"
    private static let pendingGclidKey = "trackhub.pending_gclid"
    private static let pendingGbraidKey = "trackhub.pending_gbraid"
    private static let appInstanceIdKey = "trackhub.app_instance_id"
    private static let odmInfoKey = "trackhub.google_odm_info"
    private static let adUserDataKey = "trackhub.consent.ad_user_data"
    private static let adPersonalizationKey = "trackhub.consent.ad_personalization"
    private static let eeaKey = "trackhub.consent.eea"
    private static let piplConsentKey = "trackhub.consent.pipl"
    private static let crossBorderTransferConsentKey = "trackhub.consent.cross_border_transfer"
    private static let adsMeasurementConsentKey = "trackhub.consent.ads_measurement"
    private static let adAttributionConversionTagKey = "trackhub.ad_attribution.conversion_tag"
    private static let apphudAttributionRevisionKeyPrefix = "trackhub.apphud_attribution_revision."
    private static let iso8601 = ISO8601DateFormatter()

    // MARK: - Public API

    /// Call once on launch. Reports the install (first launch only), starts
    /// session tracking, refreshes the schema and
    /// flushes buffered offline reports. `userId` is OPTIONAL — a persistent
    /// device id is generated when omitted, so the SDK needs no Apphud; set the
    /// real id later with `setUserId`.
    public static func configure(
        endpoint: URL,
        ingestToken: String,
        userId: String? = nil,
        sdkSecret: String? = nil,
        firebaseAppInstanceId: String? = nil,
        googleOnDeviceMeasurementInfo: String? = nil,
        debug: Bool = false,
        integrationTestToken: String? = nil,
        enableLegacyAsaAttribution: Bool = false,
        apphudAttributionHandler: ApphudAttributionHandler? = nil
    ) {
        // Refuse plaintext HTTP (token in transit + MITM schema poisoning); allow localhost for dev.
        guard endpoint.scheme == "https" || endpoint.host == "localhost" || endpoint.host == "127.0.0.1" else {
            print("[TrackHub] refusing non-HTTPS endpoint \(endpoint) — SDK not configured")
            return
        }
        queue.async {
            let testToken = integrationTestToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            config = Config(
                endpoint: endpoint,
                ingestToken: ingestToken,
                userId: userId ?? resolveDeviceId(),
                sdkSecret: sdkSecret,
                integrationTestToken: (testToken?.count ?? 0) >= 20 ? testToken : nil,
                legacyAsaAttributionEnabled: enableLegacyAsaAttribution,
                apphudAttributionHandler: apphudAttributionHandler
            )
            debugLogging = debug
            if let aii = firebaseAppInstanceId, !aii.isEmpty {
                UserDefaults.standard.set(aii, forKey: appInstanceIdKey)
            }
            if let info = boundedOdmInfo(googleOnDeviceMeasurementInfo) {
                UserDefaults.standard.set(info, forKey: odmInfoKey)
            }
            _ = resolveFirstOpenAt()
            schema = loadCachedSchema()
            sessionTracker = sessionTracker ?? SessionTracker()
            // Test Lab reports must never drain the production offline queue.
            // Each run gets a token-hash namespace; production keeps its stable
            // queue. Recreate on configure so switching modes cannot reuse the
            // previous in-memory queue accidentally.
            eventQueue = EventQueue(maxItems: 1000, url: queueFileURL(testToken: config?.integrationTestToken))
            SKANUpdater.registerForAttribution()
            reportInstallIfNeeded()
            fetchApphudAttributionIfNeeded()
            refreshSchema()
            startSessionTracking()
            flush()
        }
    }

    /// Update the user id after configure (e.g. once the billing SDK resolves it).
    public static func setUserId(_ userId: String) {
        queue.async {
            guard !userId.isEmpty else { return }
            config?.userId = userId
            fetchApphudAttributionIfNeeded()
        }
    }

    /// Retry the TrackHub → Apphud bridge on demand (normally configure,
    /// install/session success and setUserId trigger it automatically).
    public static func refreshApphudAttribution() {
        queue.async { fetchApphudAttributionIfNeeded() }
    }

    /// Provide the Firebase `app_instance_id` (from `Analytics.appInstanceID()`),
    /// the GA4/Firebase join key. TrackHub persists it on the install and stamps
    /// it on conversions it forwards to GA4 so a server-confirmed subscription
    /// attributes to the right install/campaign. TrackHub does NOT depend on
    /// Firebase — the host app passes the id in. Call BEFORE `configure(...)`
    /// (the install report is sent once, on first launch), or pass it via
    /// `configure(firebaseAppInstanceId:)`.
    public static func setFirebaseAppInstanceId(_ appInstanceId: String) {
        guard !appInstanceId.isEmpty else { return }
        UserDefaults.standard.set(appInstanceId, forKey: appInstanceIdKey)
    }

    /// Provide the opaque `aggregateConversionInfo` produced by Google's
    /// standalone GoogleAdsOnDeviceConversion SDK on iOS. This is NOT Firebase.
    /// Call before `configure(...)` (or pass it through
    /// `googleOnDeviceMeasurementInfo`) so the first_open request can carry
    /// `odm_info`; TrackHub caches it for later sessions and purchases.
    public static func setGoogleOnDeviceMeasurementInfo(_ info: String) {
        guard let value = boundedOdmInfo(info) else { return }
        UserDefaults.standard.set(value, forKey: odmInfoKey)
    }

    /// Stable first-launch timestamp for Google's standalone on-device
    /// measurement SDK. Safe to read before `configure(...)`.
    public static var firstOpenAt: Date { resolveFirstOpenAt() }

    /// Consent Mode signals used by App Conversion. Call before configure and
    /// whenever consent changes. A post-configure change re-reports only the
    /// install identity + latest consent; attribution stays first-write-wins.
    public static func setGoogleAdsConsent(
        adUserData: Bool,
        adPersonalization: Bool,
        eea: Bool
    ) {
        UserDefaults.standard.set(adUserData, forKey: adUserDataKey)
        UserDefaults.standard.set(adPersonalization, forKey: adPersonalizationKey)
        UserDefaults.standard.set(eea, forKey: eeaKey)
        queue.async { reportConsentUpdateIfInstalled() }
    }

    /// Mainland-China PIPL signals. Call after your consent UI resolves them.
    /// TrackHub fails closed for Google cross-border ads measurement once these
    /// signals are in use and transfer/measurement consent is not granted.
    public static func setPIPLConsent(
        piplConsent: Bool,
        crossBorderTransferConsent: Bool,
        adsMeasurementConsent: Bool
    ) {
        UserDefaults.standard.set(piplConsent, forKey: piplConsentKey)
        UserDefaults.standard.set(crossBorderTransferConsent, forKey: crossBorderTransferConsentKey)
        UserDefaults.standard.set(adsMeasurementConsent, forKey: adsMeasurementConsentKey)
        queue.async { reportConsentUpdateIfInstalled() }
    }

    /// Record Google click identifiers captured from an app/universal link.
    /// `gclid` and `gbraid` are attached to the corresponding session_start;
    /// install-time values also ride the one-shot install report. `wbraid` is
    /// retained for the separate web/offline conversion contour.
    public static func setGoogleClickId(gclid: String? = nil, gbraid: String? = nil, wbraid: String? = nil) {
        storeGoogleClickIds(gclid: gclid, gbraid: gbraid, wbraid: wbraid)
        if gclid?.isEmpty == false || gbraid?.isEmpty == false {
            queue.async {
                if config != nil { handleForeground(force: true) }
            }
        }
    }

    private static func storeGoogleClickIds(gclid: String?, gbraid: String?, wbraid: String?) {
        if let c = gclid, !c.isEmpty {
            UserDefaults.standard.set(c, forKey: gclidKey)
            UserDefaults.standard.set(c, forKey: pendingGclidKey)
        }
        if let g = gbraid, !g.isEmpty { UserDefaults.standard.set(g, forKey: gbraidKey) }
        if let g = gbraid, !g.isEmpty { UserDefaults.standard.set(g, forKey: pendingGbraidKey) }
        if let w = wbraid, !w.isEmpty { UserDefaults.standard.set(w, forKey: wbraidKey) }
    }

    /// Convenience over `setGoogleClickId`: extracts `gclid` / `gbraid` / `wbraid` from a
    /// deep-link / universal-link URL's query and stores them. Returns true if a
    /// Google click id was found. Call from your URL handler and, on a cold launch
    /// from a click, from the launch URL — before `configure(...)`.
    @discardableResult
    public static func handleDeepLink(_ url: URL) -> Bool {
        let ids = parseGoogleClickIds(from: url)
        guard ids.gclid != nil || ids.gbraid != nil || ids.wbraid != nil else { return false }
        // Store first, then force exactly one session below. Calling the public
        // setter here would schedule a second forced session.
        storeGoogleClickIds(gclid: ids.gclid, gbraid: ids.gbraid, wbraid: ids.wbraid)
        if ids.gclid != nil || ids.gbraid != nil {
            queue.async {
                if config != nil { handleForeground(force: true) }
            }
        }
        return true
    }

    /// Captures the conversion tag Apple appends to an AdAttributionKit
    /// re-engagement universal link. The returned tag can be passed to
    /// `trackEvent(..., conversionTag:)` to update that exact overlapping
    /// conversion window on iOS 18.4+. The latest tag is also cached as a
    /// convenience for `.reengagement` updates.
    @discardableResult
    public static func handleAdAttributionReengagement(_ url: URL) -> String? {
        guard let tag = parseAdAttributionReengagementConversionTag(from: url) else { return nil }
        UserDefaults.standard.set(tag, forKey: adAttributionConversionTagKey)
        queue.async {
            if config != nil { handleForeground(force: true) }
        }
        return tag
    }

    @_spi(Testing) public static func parseAdAttributionReengagementConversionTag(
        from url: URL
    ) -> String? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "AdAttributionKitReengagementOpen" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Pure URL extraction (empty values treated as absent).
    @_spi(Testing) public static func parseGoogleClickIds(from url: URL) -> (gclid: String?, gbraid: String?, wbraid: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let v = items.first { $0.name == name }?.value
            return (v?.isEmpty == false) ? v : nil
        }
        return (value("gclid"), value("gbraid"), value("wbraid"))
    }

    /// Tracks a non-financial engagement event → TrackHub analytics and applies
    /// the SKAN conversion value when the active schema has a matching rule.
    /// Purchases use `trackPurchaseObserved`; Apphud remains authoritative for
    /// revenue/value/currency.
    public static func trackEvent(
        _ name: String,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:],
        adAttributionTarget: AdAttributionConversionTarget = .all,
        conversionTag: String? = nil
    ) {
        queue.async {
            guard let config else { return log("trackEvent(\(name)) before configure — skipped") }
            var body: [String: Any] = [
                "client_event_id": UUID().uuidString,
                "event_name": name,
                "user_id": config.userId,
                "occurred_at": iso8601.string(from: Date()),
                "first_open_at": iso8601.string(from: resolveFirstOpenAt()),
                "sdk_version": Self.sdkVersion,
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "locale": Locale.current.identifier,
            ]
            if let country = currentCountryCode() { body["country"] = country }
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                body["app_version"] = version
            }
            if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                body["build"] = build
            }
            appendOdmInfo(to: &body)
            appendAppConversionDeviceIdentifier(to: &body)
            if !callbackParams.isEmpty { body["callback_params"] = callbackParams }
            if !partnerParams.isEmpty { body["partner_params"] = partnerParams }
            send(path: "sdk/track", body: body)
        }
        track(
            name,
            adAttributionTarget: adAttributionTarget,
            conversionTag: conversionTag
        )
    }

    /// Records only the device-side observation needed by Google's App
    /// Conversion API. No money is accepted here: the matching Apphud webhook
    /// supplies verified value/currency. `transactionId` must be the same stable
    /// store transaction id Apphud sends. Requires `sdkSecret` because the
    /// server rejects unsigned purchase contexts.
    public static func trackPurchaseObserved(transactionId: String, productId: String? = nil) {
        guard !transactionId.isEmpty else { return }
        queue.async {
            guard let config else { return log("trackPurchaseObserved before configure — skipped") }
            guard config.sdkSecret?.isEmpty == false else {
                return log("trackPurchaseObserved requires sdkSecret — skipped")
            }
            send(
                path: "sdk/purchase-context",
                body: purchaseContextBody(
                    transactionId: transactionId,
                    productId: productId,
                    userId: config.userId
                )
            )
        }
    }

    #if canImport(StoreKit)
    /// StoreKit 2 convenience overload. Pass the verified transaction surfaced
    /// by the host app's/Apphud's successful purchase flow.
    @available(iOS 15.0, macOS 12.0, *)
    public static func trackPurchaseObserved(_ transaction: StoreKit.Transaction) {
        trackPurchaseObserved(
            transactionId: String(transaction.id),
            productId: transaction.productID
        )
    }
    #endif

    @_spi(Testing) public static func purchaseContextBody(
        transactionId: String,
        productId: String?,
        userId: String,
        occurredAt: Date = Date(),
        firstOpenAt: Date? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "transaction_id": transactionId,
            "user_id": userId,
            "occurred_at": iso8601.string(from: occurredAt),
            "first_open_at": iso8601.string(from: firstOpenAt ?? resolveFirstOpenAt()),
            "sdk_version": Self.sdkVersion,
            "locale": Locale.current.identifier,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let productId, !productId.isEmpty { body["product_id"] = productId }
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["app_version"] = v
        }
        if let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { body["build"] = b }
        if let country = currentCountryCode() { body["country"] = country }
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        return body
    }

    /// Applies the on-device SKAN and AdAttributionKit conversion values for
    /// `event` (no analytics — use `trackEvent` for that). On iOS 18+, target
    /// install or re-engagement postbacks independently; on iOS 18.4+, pass a
    /// conversion tag to update one overlapping re-engagement window.
    public static func track(
        _ event: String,
        revenueCents: Int? = nil,
        adAttributionTarget: AdAttributionConversionTarget = .all,
        conversionTag: String? = nil
    ) {
        queue.async {
            guard let schema else { return log("track(\(event)) before schema is available — skipped") }
            guard let update = ConversionEncoder.encode(schema: schema, event: event, revenueCents: revenueCents) else {
                return log("event \(event) has no rule in schema v\(schema.schemaVersion)")
            }
            log("event \(event) → fine \(update.fine), coarse \(update.coarse ?? "—"), lock \(update.lockWindow)")
            let resolvedTag = conversionTag ?? (
                adAttributionTarget == .reengagement
                    ? UserDefaults.standard.string(forKey: adAttributionConversionTagKey)
                    : nil
            )
            SKANUpdater.apply(
                update,
                adAttributionTarget: adAttributionTarget,
                conversionTag: resolvedTag
            )
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
    private static func handleForeground(force: Bool = false) {
        guard let config, let tracker = sessionTracker else { return }
        let started: SessionStart?
        if force {
            started = tracker.forceForeground()
        } else {
            started = tracker.foreground()
        }
        guard let started else { return }
        var body: [String: Any] = [
            "user_id": config.userId,
            "session_uid": started.sessionUid,
            "session_num": started.sessionNum,
            "started_at": iso8601.string(from: started.startedAt),
            "first_open_at": iso8601.string(from: resolveFirstOpenAt()),
            "sdk_version": Self.sdkVersion,
            "locale": Locale.current.identifier,
        ]
        if let country = currentCountryCode() { body["country"] = country }
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = v }
        if let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { body["build"] = b }
        body["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        let defaults = UserDefaults.standard
        if let gclid = defaults.string(forKey: pendingGclidKey) { body["gclid"] = gclid }
        if let gbraid = defaults.string(forKey: pendingGbraidKey) { body["gbraid"] = gbraid }
        defaults.removeObject(forKey: pendingGclidKey)
        defaults.removeObject(forKey: pendingGbraidKey)
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        send(path: "sdk/session", body: body) { status in
            if isSuccess(status) { queue.async { fetchApphudAttributionIfNeeded() } }
        }
    }

    private static func handleBackground() { sessionTracker?.background() }

    // MARK: - Install

    private static func reportInstallIfNeeded() {
        guard let config else { return }
        let isIntegrationTest = config.integrationTestToken != nil
        guard isIntegrationTest || !UserDefaults.standard.bool(forKey: installSentKey) else { return }
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
        body["locale"] = Locale.current.identifier
        if let country = currentCountryCode() { body["country"] = country }
        if let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { body["build"] = b }
        body["occurred_at"] = iso8601.string(from: resolveFirstOpenAt())
        if config.legacyAsaAttributionEnabled,
           let token = SKANUpdater.attributionToken() {
            body["adservices_token"] = token
        }
        // Google click ids captured from a deep link (set via setGoogleClickId /
        // handleDeepLink before configure) — the iOS path for user-level Google
        // attribution + conversion return.
        if let c = UserDefaults.standard.string(forKey: gclidKey) { body["gclid"] = c }
        if let g = UserDefaults.standard.string(forKey: gbraidKey) { body["gbraid"] = g }
        if let w = UserDefaults.standard.string(forKey: wbraidKey) { body["wbraid"] = w }
        // Firebase app_instance_id (GA4 join key for server-confirmed conversions).
        if let aii = UserDefaults.standard.string(forKey: appInstanceIdKey) { body["app_instance_id"] = aii }
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        appendConsent(to: &body)
        if let testToken = config.integrationTestToken { body["test_run_token"] = testToken }

        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        postRaw(path: "install", bodyData: data) { status in
            if isSuccess(status) {
                if !isIntegrationTest { UserDefaults.standard.set(true, forKey: installSentKey) }
                log(isIntegrationTest ? "integration-test install reported" : "install reported")
                if !isIntegrationTest {
                    queue.async {
                        reportConsentUpdate()
                        fetchApphudAttributionIfNeeded()
                    }
                }
            }
            else { log("install report failed — will retry on next launch") }
        }
    }

    private static func appendConsent(to body: inout [String: Any]) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: adUserDataKey) != nil {
            body["ad_user_data"] = defaults.bool(forKey: adUserDataKey)
        }
        if defaults.object(forKey: adPersonalizationKey) != nil {
            body["ad_personalization"] = defaults.bool(forKey: adPersonalizationKey)
        }
        if defaults.object(forKey: eeaKey) != nil { body["eea"] = defaults.bool(forKey: eeaKey) }
        if defaults.object(forKey: piplConsentKey) != nil {
            body["pipl_consent"] = defaults.bool(forKey: piplConsentKey)
        }
        if defaults.object(forKey: crossBorderTransferConsentKey) != nil {
            body["cross_border_transfer_consent"] = defaults.bool(forKey: crossBorderTransferConsentKey)
        }
        if defaults.object(forKey: adsMeasurementConsentKey) != nil {
            body["ads_measurement_consent"] = defaults.bool(forKey: adsMeasurementConsentKey)
        }
    }

    private static func reportConsentUpdate() {
        guard let config else { return }
        var body: [String: Any] = [
            "user_id": config.userId,
            "sdk_name": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
            "platform": "ios",
        ]
        appendConsent(to: &body)
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        send(path: "install", body: body)
    }

    private static func reportConsentUpdateIfInstalled() {
        guard config != nil, UserDefaults.standard.bool(forKey: installSentKey) else { return }
        reportConsentUpdate()
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

    // MARK: - Apphud attribution bridge

    private struct ApphudAttributionEnvelope: Decodable {
        let ok: Bool
        let attribution: ApphudAttributionSnapshot?
    }

    private struct ApphudAttributionSnapshot: Decodable {
        let revision: String
        let provider: String
        let data: [String: String]
    }

    private static func apphudAttributionRevisionKey(userId: String) -> String {
        let digest = SHA256.hash(data: Data(userId.utf8))
        let suffix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return apphudAttributionRevisionKeyPrefix + suffix
    }

    @_spi(Testing) public static func shouldDeliverApphudAttribution(
        revision: String,
        userId: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.string(forKey: apphudAttributionRevisionKey(userId: userId)) != revision
    }

    @_spi(Testing) public static func markApphudAttributionDelivered(
        revision: String,
        userId: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(revision, forKey: apphudAttributionRevisionKey(userId: userId))
    }

    // On `queue`. Only production calls are eligible: a Test Lab run must not
    // mutate the real Apphud customer profile.
    private static func fetchApphudAttributionIfNeeded() {
        guard !apphudAttributionFetchInFlight, let config,
              config.integrationTestToken == nil,
              let handler = config.apphudAttributionHandler else { return }
        guard config.sdkSecret?.isEmpty == false else {
            return log("Apphud attribution bridge requires sdkSecret")
        }
        let body: [String: Any] = [
            "user_id": config.userId,
            "event_at": iso8601.string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        apphudAttributionFetchInFlight = true
        postRawResponse(path: "sdk/attribution", bodyData: data) { status, responseData in
            queue.async {
                apphudAttributionFetchInFlight = false
                guard isSuccess(status), let responseData,
                      let envelope = try? JSONDecoder().decode(ApphudAttributionEnvelope.self, from: responseData),
                      envelope.ok, let snapshot = envelope.attribution,
                      snapshot.provider == "custom" else {
                    if isRetryable(status) { log("Apphud attribution fetch failed — will retry") }
                    return
                }
                guard shouldDeliverApphudAttribution(
                    revision: snapshot.revision,
                    userId: config.userId
                ) else { return }
                DispatchQueue.main.async {
                    handler(snapshot.data) { accepted in
                        queue.async {
                            if accepted {
                                markApphudAttributionDelivered(
                                    revision: snapshot.revision,
                                    userId: config.userId
                                )
                                log("Apphud attribution revision \(snapshot.revision) delivered")
                            } else {
                                log("Apphud rejected attribution — will retry")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Offline buffer + networking

    @_spi(Testing) public static func offlineQueueNamespace(for testToken: String?) -> String {
        guard let token = testToken, !token.isEmpty else { return "production" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return "test-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func queueFileURL(testToken: String?) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let namespace = offlineQueueNamespace(for: testToken)
        // Preserve the pre-Test-Lab production filename so an SDK upgrade still
        // drains already-buffered real events.
        let filename = namespace == "production" ? "trackhub_queue.json" : "trackhub_queue_\(namespace).json"
        return dir.appendingPathComponent(filename)
    }

    // Send a report; on failure (offline / 5xx) buffer it for retry next launch.
    private static func send(
        path: String,
        body: [String: Any],
        completion: ((Int?) -> Void)? = nil
    ) {
        var payload = body
        if let testToken = config?.integrationTestToken { payload["test_run_token"] = testToken }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        // Capture the queue that belongs to this delivery. A configure() mode
        // switch may happen before URLSession calls us back; consulting the
        // mutable global then could put a production failure in a Test Lab
        // queue (or the reverse).
        let targetQueue = eventQueue
        postRaw(path: path, bodyData: data) { status in
            if isRetryable(status) {
                queue.async { targetQueue?.enqueue(PendingReport(path: path, body: data)) }
            } else if !isSuccess(status) {
                log("report rejected with HTTP \(status ?? 0) — not queued")
            }
            completion?(status)
        }
    }

    // Drain buffered reports; each is signed FRESH at send time so a stale
    // timestamp never rejects buffered traffic. Success/permanent rejects pop;
    // only transient failures stay.
    private static func flush() {
        guard let q = eventQueue else { return }
        for report in q.items {
            postRaw(path: report.path, bodyData: report.body) { status in
                // Success and permanent 3xx/4xx responses leave the queue;
                // transport failures, 408/429 and 5xx remain for retry.
                if !isRetryable(status) {
                    queue.async { q.remove(id: report.id) }
                }
            }
        }
    }

    private static func resolveDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let id = "dev_" + UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    // Google's App Conversion API requires `fot` on every post-install event.
    // Persist the SDK's first observed launch before any asynchronous network
    // request starts, so session/purchase reports remain valid even if they
    // reach the server before the install report.
    private static func resolveFirstOpenAt() -> Date {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: firstOpenAtKey),
           let date = iso8601.date(from: stored) {
            return date
        }
        let date = Date()
        defaults.set(iso8601.string(from: date), forKey: firstOpenAtKey)
        return date
    }

    private static func currentCountryCode() -> String? {
        let code: String?
        if #available(iOS 16.0, macOS 13.0, *) {
            code = Locale.current.region?.identifier
        } else {
            code = Locale.current.regionCode
        }
        guard let code, code.count == 2 else { return nil }
        return code.uppercased()
    }

    private static func boundedOdmInfo(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { return nil }
        return value
    }

    private static func appendOdmInfo(to body: inout [String: Any]) {
        if let info = boundedOdmInfo(UserDefaults.standard.string(forKey: odmInfoKey)) {
            body["odm_info"] = info
        }
    }

    private static func appendAppConversionDeviceIdentifier(to body: inout [String: Any]) {
        #if os(iOS)
        // Google documents IDFV as the iOS fallback when IDFA is unavailable.
        // TrackHub does not read IDFA; the fallback is always limited-tracking.
        guard config?.sdkSecret?.isEmpty == false,
              let value = UIDevice.current.identifierForVendor?.uuidString else { return }
        body["device_id"] = value
        body["device_id_type"] = "idfv"
        body["limit_ad_tracking"] = true
        #endif
    }

    // Signs `bodyData` with a FRESH timestamp at call time (so reports re-sent
    // from the offline buffer stay within the server's ±5min replay window).
    private static func isSuccess(_ status: Int?) -> Bool {
        guard let status else { return false }
        return (200..<300).contains(status)
    }

    private static func isRetryable(_ status: Int?) -> Bool {
        guard let status else { return true }
        return status == 408 || status == 429 || status >= 500
    }

    private static func postRaw(path: String, bodyData: Data, completion: @escaping (Int?) -> Void) {
        postRawResponse(path: path, bodyData: bodyData) { status, _ in completion(status) }
    }

    private static func postRawResponse(
        path: String,
        bodyData: Data,
        completion: @escaping (Int?, Data?) -> Void
    ) {
        guard let config else { return completion(nil, nil) }
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
        URLSession.shared.dataTask(with: request) { data, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode, data)
        }.resume()
    }

    static func log(_ message: String) {
        if debugLogging { print("[TrackHub] \(message)") }
    }
}
