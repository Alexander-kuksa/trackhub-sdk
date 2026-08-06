import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif
#if canImport(StoreKit)
import StoreKit
#endif
#if os(iOS)
import UIKit
#endif
#if os(iOS) && canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if os(iOS) && canImport(AdSupport)
import AdSupport
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
/// dependency on ApphudSDK: pass `data` to `Apphud.setAttribution(..., .custom)`
/// and call `completion(true)` only when Apphud acknowledges it.
public typealias ApphudAttributionHandler = (
    _ data: [String: String],
    _ completion: @escaping (Bool) -> Void
) -> Void

/// Adapter for Apphud's official `setDeviceIdentifiers(idfa:idfv:)` method.
/// TrackHub sends IDFV immediately after configuration and sends IDFA only when
/// App Tracking Transparency is authorized.
public typealias ApphudDeviceIdentifiersHandler = (
    _ idfa: String?,
    _ idfv: String?
) -> Void

public struct TrackHubAttribution: Sendable, Equatable {
    public let revision: String
    public let status: String
    public let network: String
    public let channel: String
    public let campaignId: String?
    public let adGroupId: String?
    public let keywordId: String?
    public let touchpointKind: String?
    public let source: String?
    public let data: [String: String]
}

public typealias TrackHubAttributionChangedHandler = (TrackHubAttribution) -> Void
public typealias TrackHubDeferredDeepLinkHandler = (String?) -> Void

/// Supplies the raw TrackHub attribution JSON through the host app's trusted
/// backend. That backend authenticates to `/sdk/attribution` with its linked
/// S2S secret; the secret must never be embedded in the mobile app.
public typealias TrackHubBackendAttributionProvider = (
    _ userId: String,
    _ completion: @escaping (Data?) -> Void
) -> Void

/// Requests privacy erasure through the host app's trusted backend. The
/// backend calls `/sdk/forget-device` with its linked S2S secret and reports
/// whether TrackHub accepted the erasure.
public typealias TrackHubBackendPrivacyErasureHandler = (
    _ userId: String,
    _ reason: String,
    _ completion: @escaping (Bool) -> Void
) -> Void

public enum TrackHubTrackingAuthorizationStatus: String, Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case unavailable
}

public enum TrackHubPushEnvironment: String, Sendable, Equatable {
    case production
    case sandbox
}

public enum TrackHubSalesPlacement: String, CaseIterable, Sendable, Equatable {
    case onboarding = "onboarding_placement"
    case inApp = "inapp_placement"
    case special = "special_placement"
    case settings = "settings_placement"
    case onLaunch = "on_launch_placement"
    case quickAction = "quick_action_placement"
    case transactionAbandonment = "transaction_abandonment_placement"
}

public enum TrackHubSalesEvent: String, Sendable, Equatable {
    case onboardingShown = "ob_shown"
    case paywallShown = "pw_shown"
    case purchaseCtaTapped = "purchase_cta_tapped"
}

public enum TrackHub {
    /// SDK version reported to the platform for integration detection.
    public static let sdkVersion = "1.10.0"

    private static let queue = DispatchQueue(label: "com.trackhub.sdk")
    private static var config: Config?
    private static var schema: ConversionSchema?
    private static var debugLogging = false
    private static var sessionTracker: SessionTracker?
    private static var eventQueue: EventQueue?
    private static let httpClient = BoundedHTTPClient()
    private static var deliveryInFlight = false
    private static var retryWorkItem: DispatchWorkItem?
    private static var retryDeadline: Date?
    private static var transientRetryNotBefore: Date?
    private static var deliveryCompletions: [String: (Int?) -> Void] = [:]
    private static var apphudAttributionFetchInFlight = false
    private static var attributionFetchGeneration: UInt64 = 0
    private static var activeForgetRequests: Set<UUID> = []
    private static var currentAttributionSnapshot: TrackHubAttribution?
    private static var attributionCompletions: [(TrackHubAttribution?) -> Void] = []
    private static var trackingDisabled = false
    private static var attConsentDelayActive = false
    private static var attConsentDelayWorkItem: DispatchWorkItem?
    #if os(iOS)
    private static var lifecycleObserver: LifecycleObserver?
    #endif

    struct Config {
        let endpoint: URL
        let ingestToken: String
        var userId: String
        let sdkSecret: String?
        let integrationTestToken: String?
        let attConsentWaitingInterval: TimeInterval
        let legacyAsaAttributionEnabled: Bool
        let apphudDeviceIdentifiersHandler: ApphudDeviceIdentifiersHandler?
        let backendAttributionProvider: TrackHubBackendAttributionProvider?
        let backendPrivacyErasureHandler: TrackHubBackendPrivacyErasureHandler?
        let apphudAttributionHandler: ApphudAttributionHandler?
        let attributionChangedHandler: TrackHubAttributionChangedHandler?
        let deferredDeepLinkHandler: TrackHubDeferredDeepLinkHandler?
    }

    private struct NetworkConfig {
        let endpoint: URL
        let ingestToken: String
        let sdkSecret: String?
    }

    private static let schemaCacheKey = "trackhub.cv_schema"
    private static let installSentKey = "trackhub.install_sent"
    private static let firstOpenAtKey = "trackhub.first_open_at"
    private static let deviceIdKey = "trackhub.device_id"
    private static let installUidKey = "trackhub.install_uid"
    private static let pushTokenKey = "trackhub.push_token.apns"
    private static let pushEnvironmentKey = "trackhub.push_environment.apns"
    private static let gclidKey = "trackhub.gclid"
    private static let gbraidKey = "trackhub.gbraid"
    private static let wbraidKey = "trackhub.wbraid"
    private static let pendingGclidKey = "trackhub.pending_gclid"
    private static let pendingGbraidKey = "trackhub.pending_gbraid"
    private static let openAiOpprefKey = "trackhub.openai_oppref"
    private static let pendingOpenAiOpprefKey = "trackhub.pending_openai_oppref"
    private static let appInstanceIdKey = "trackhub.app_instance_id"
    private static let odmInfoKey = "trackhub.google_odm_info"
    private static let adUserDataKey = "trackhub.consent.ad_user_data"
    private static let adPersonalizationKey = "trackhub.consent.ad_personalization"
    private static let eeaKey = "trackhub.consent.eea"
    private static let countryCodeKey = "trackhub.country_code"
    private static let piplConsentKey = "trackhub.consent.pipl"
    private static let crossBorderTransferConsentKey = "trackhub.consent.cross_border_transfer"
    private static let adsMeasurementConsentKey = "trackhub.consent.ads_measurement"
    private static let adAttributionConversionTagKey = "trackhub.ad_attribution.conversion_tag"
    private static let apphudAttributionRevisionKeyPrefix = "trackhub.apphud_attribution_revision."
    private static let privacyDisabledKeyPrefix = "trackhub.privacy_disabled."
    private static let iso8601 = ISO8601DateFormatter()
    private static let callbackTimeout: TimeInterval = 15
    private static let maxReportBytes = EventQueue.defaultMaxItemBytes
    private static let retryBaseInterval: TimeInterval = 1
    private static let retryMaxInterval: TimeInterval = 5 * 60

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
        countryCode: String? = nil,
        debug: Bool = false,
        integrationTestToken: String? = nil,
        attConsentWaitingInterval: TimeInterval = 0,
        enableLegacyAsaAttribution: Bool = false,
        apphudDeviceIdentifiersHandler: ApphudDeviceIdentifiersHandler? = nil,
        backendAttributionProvider: TrackHubBackendAttributionProvider? = nil,
        backendPrivacyErasureHandler: TrackHubBackendPrivacyErasureHandler? = nil,
        apphudAttributionHandler: ApphudAttributionHandler? = nil,
        attributionChangedHandler: TrackHubAttributionChangedHandler? = nil,
        deferredDeepLinkHandler: TrackHubDeferredDeepLinkHandler? = nil
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
                attConsentWaitingInterval: normalizedATTConsentWaitingInterval(attConsentWaitingInterval),
                legacyAsaAttributionEnabled: enableLegacyAsaAttribution,
                apphudDeviceIdentifiersHandler: apphudDeviceIdentifiersHandler,
                backendAttributionProvider: backendAttributionProvider,
                backendPrivacyErasureHandler: backendPrivacyErasureHandler,
                apphudAttributionHandler: apphudAttributionHandler,
                attributionChangedHandler: attributionChangedHandler,
                deferredDeepLinkHandler: deferredDeepLinkHandler
            )
            trackingDisabled = UserDefaults.standard.bool(
                forKey: privacyDisabledKey(token: ingestToken)
            )
            debugLogging = debug
            if trackingDisabled {
                log("tracking disabled after a forget-device request")
                return
            }
            if let aii = firebaseAppInstanceId, !aii.isEmpty {
                UserDefaults.standard.set(aii, forKey: appInstanceIdKey)
            }
            if let info = boundedOdmInfo(googleOnDeviceMeasurementInfo) {
                UserDefaults.standard.set(info, forKey: odmInfoKey)
            }
            if let country = normalizedCountryCode(countryCode) {
                UserDefaults.standard.set(country, forKey: countryCodeKey)
            }
            _ = resolveFirstOpenAt()
            schema = loadCachedSchema()
            sessionTracker = sessionTracker ?? SessionTracker()
            // Test Lab reports must never drain the production offline queue.
            // Each run gets a token-hash namespace; production keeps its stable
            // queue. Recreate on configure so switching modes cannot reuse the
            // previous in-memory queue accidentally.
            retryWorkItem?.cancel()
            retryWorkItem = nil
            retryDeadline = nil
            transientRetryNotBefore = nil
            eventQueue = EventQueue(url: queueFileURL(testToken: config?.integrationTestToken))
            startATTConsentDelayIfNeeded()
            publishApphudDeviceIdentifiers()
            SKANUpdater.registerForAttribution()
            reportInstallIfNeeded()
            reportPushTokenIfAvailable()
            fetchAttributionIfNeeded()
            resolveDeferredDeepLinkIfNeeded()
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
            reportPushTokenIfAvailable()
            fetchAttributionIfNeeded()
        }
    }

    /// Forward the APNs registration token supplied by the host app. TrackHub
    /// does not request notification permission and does not register for
    /// remote notifications itself. Call from
    /// application(_:didRegisterForRemoteNotificationsWithDeviceToken:).
    public static func setPushToken(
        _ deviceToken: Data,
        environment: TrackHubPushEnvironment = .production
    ) {
        let value = deviceToken.map { String(format: "%02x", $0) }.joined()
        setPushToken(value, environment: environment)
    }

    /// String overload for wrappers that already expose the APNs token as hex.
    public static func setPushToken(
        _ deviceToken: String,
        environment: TrackHubPushEnvironment = .production
    ) {
        let value = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 32, value.count <= 4096 else { return }
        UserDefaults.standard.set(value, forKey: pushTokenKey)
        UserDefaults.standard.set(environment.rawValue, forKey: pushEnvironmentKey)
        queue.async { reportPushTokenIfAvailable() }
    }

    /// Retry the TrackHub → Apphud bridge on demand (normally configure,
    /// install/session success and setUserId trigger it automatically).
    public static func refreshApphudAttribution() {
        queue.async { fetchAttributionIfNeeded() }
    }

    /// Returns the durable TrackHub attribution snapshot. The completion is
    /// always delivered on the main queue. A network refresh is made when the
    /// current process has not fetched a snapshot yet.
    public static func getAttribution(
        completion: @escaping (TrackHubAttribution?) -> Void
    ) {
        queue.async {
            if let currentAttributionSnapshot {
                return DispatchQueue.main.async { completion(currentAttributionSnapshot) }
            }
            fetchAttributionIfNeeded(completion: completion)
        }
    }

    /// Resolves a TrackHub measurement-link deep link once. The returned value
    /// is the opaque path configured for the link (for example `/offer/annual`).
    public static func resolveDeferredDeepLink(
        completion: @escaping TrackHubDeferredDeepLinkHandler
    ) {
        queue.async { resolveDeferredDeepLinkIfNeeded(completion: completion) }
    }

    /// Permanently erases this app/user identity through the host app's trusted
    /// backend and disables subsequent SDK delivery for this install only after
    /// the backend confirms TrackHub accepted the request.
    public static func forgetDevice(
        reason: String = "user_requested",
        completion: ((Bool) -> Void)? = nil
    ) {
        queue.async {
            guard let config, let handler = config.backendPrivacyErasureHandler else {
                log("forget-device requires backendPrivacyErasureHandler")
                return DispatchQueue.main.async { completion?(false) }
            }
            let boundedReason = String(reason.prefix(256))
            let requestID = UUID()
            activeForgetRequests.insert(requestID)
            let finish: (Bool) -> Void = { accepted in
                queue.async {
                    guard activeForgetRequests.remove(requestID) != nil else { return }
                    if accepted {
                        trackingDisabled = true
                        UserDefaults.standard.set(true, forKey: privacyDisabledKey(token: config.ingestToken))
                        currentAttributionSnapshot = nil
                        retryWorkItem?.cancel()
                        retryWorkItem = nil
                        retryDeadline = nil
                        transientRetryNotBefore = nil
                        deliveryCompletions.removeAll()
                        for key in [
                            pushTokenKey, pushEnvironmentKey, deviceIdKey, installUidKey,
                            gclidKey, gbraidKey, wbraidKey, pendingGclidKey, pendingGbraidKey,
                            openAiOpprefKey, pendingOpenAiOpprefKey,
                            appInstanceIdKey, odmInfoKey,
                        ] {
                            UserDefaults.standard.removeObject(forKey: key)
                        }
                        if eventQueue?.removeAll() == false {
                            log("forget-device could not erase the offline queue")
                        }
                    }
                    DispatchQueue.main.async { completion?(accepted) }
                }
            }
            queue.asyncAfter(deadline: .now() + callbackTimeout) {
                guard activeForgetRequests.contains(requestID) else { return }
                log("forget-device backend timed out")
                finish(false)
            }
            DispatchQueue.main.async {
                handler(config.userId, boundedReason, finish)
            }
        }
    }

    /// Re-send the currently available identifiers to Apphud. Configuration
    /// already does this once; the ATT completion also calls it automatically.
    public static func syncApphudDeviceIdentifiers() {
        queue.async { publishApphudDeviceIdentifiers() }
    }

    /// Present Apple's ATT prompt. Call this only after the app's contextual
    /// explanation, at the product-appropriate moment. It is intentionally not
    /// shown automatically from `configure`, because launch-time permission
    /// prompts produce poor consent quality and make onboarding brittle.
    ///
    /// `NSUserTrackingUsageDescription` must be present in the host app's
    /// Info.plist. IDFV is available regardless of the result; IDFA is exposed
    /// and sent to Apphud/TrackHub only after `.authorized`.
    public static func requestAppTrackingTransparency(
        completion: ((TrackHubTrackingAuthorizationStatus) -> Void)? = nil
    ) {
        #if os(iOS) && canImport(AppTrackingTransparency) && canImport(AdSupport)
        DispatchQueue.main.async {
            let usage = Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") as? String
            guard usage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                log("NSUserTrackingUsageDescription is missing — ATT prompt skipped")
                queue.async {
                    finishATTConsentDelay(reason: "usage description missing")
                }
                completion?(.unavailable)
                return
            }
            ATTrackingManager.requestTrackingAuthorization { status in
                let mapped = trackingAuthorizationStatus(status)
                queue.async {
                    publishApphudDeviceIdentifiers()
                    // Apple can return notDetermined without presenting a prompt
                    // when the app is inactive or another permission sheet is
                    // already visible. Keep waiting in that case; a later retry
                    // or the hard timeout will release the first session.
                    if mapped != .notDetermined {
                        finishATTConsentDelay(reason: "ATT resolved: \(mapped.rawValue)")
                    }
                    reportConsentUpdateIfInstalled()
                }
                DispatchQueue.main.async { completion?(mapped) }
            }
        }
        #else
        DispatchQueue.main.async { completion?(.unavailable) }
        #endif
    }

    /// Adjust-style bounded first-session wait. The value is deliberately
    /// opt-in and capped at 360 seconds, matching Adjust's current ATT waiting
    /// window. Apphud still receives IDFV immediately; only TrackHub's first
    /// install/session/event network delivery waits for ATT or the timeout.
    @_spi(Testing) public static func normalizedATTConsentWaitingInterval(
        _ value: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, 360)
    }

    @_spi(Testing) public static func shouldDelayFirstSessionForATT(
        waitingInterval: TimeInterval,
        status: TrackHubTrackingAuthorizationStatus,
        installAlreadySent: Bool,
        integrationTest: Bool
    ) -> Bool {
        normalizedATTConsentWaitingInterval(waitingInterval) > 0 &&
            status == .notDetermined &&
            !installAlreadySent &&
            !integrationTest
    }

    // On `queue`. Apple registration/schema work continues immediately; only
    // user-level TrackHub delivery is held. Calls made during the wait go into
    // the existing disk-backed FIFO so an app termination cannot lose them.
    private static func startATTConsentDelayIfNeeded() {
        attConsentDelayWorkItem?.cancel()
        attConsentDelayWorkItem = nil
        attConsentDelayActive = false
        #if os(iOS) && canImport(AppTrackingTransparency)
        guard let config else { return }
        let status = trackingAuthorizationStatus(ATTrackingManager.trackingAuthorizationStatus)
        let installAlreadySent = UserDefaults.standard.bool(forKey: installSentKey)
        guard shouldDelayFirstSessionForATT(
            waitingInterval: config.attConsentWaitingInterval,
            status: status,
            installAlreadySent: installAlreadySent,
            integrationTest: config.integrationTestToken != nil
        ) else { return }

        let interval = config.attConsentWaitingInterval
        attConsentDelayActive = true
        let workItem = DispatchWorkItem {
            finishATTConsentDelay(reason: "timeout after \(Int(interval))s")
        }
        attConsentDelayWorkItem = workItem
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
        log("first session waiting up to \(Int(interval))s for ATT")
        #endif
    }

    // On `queue`. Idempotent so ATT completion and timeout may race safely.
    private static func finishATTConsentDelay(reason: String) {
        guard attConsentDelayActive else { return }
        attConsentDelayActive = false
        attConsentDelayWorkItem?.cancel()
        attConsentDelayWorkItem = nil
        log("first-session ATT wait ended (\(reason))")
        reportInstallIfNeeded()
        flush()
        fetchAttributionIfNeeded()
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

    /// Set the actual ISO-3166 country where measurement originates. Do not
    /// derive this from the device language/Locale: a user can travel or choose
    /// a language unrelated to their current country. A trusted server edge may
    /// override this value from its geo header.
    public static func setCountryCode(_ countryCode: String) {
        guard let value = normalizedCountryCode(countryCode) else { return }
        UserDefaults.standard.set(value, forKey: countryCodeKey)
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

    /// Captures supported ad click references from a deep/universal link:
    /// Google `gclid`/`gbraid`/`wbraid` and OpenAI Ads `oppref`.
    @discardableResult
    public static func handleDeepLink(_ url: URL) -> Bool {
        let ids = parseGoogleClickIds(from: url)
        let oppref = parseOpenAiOppref(from: url)
        guard ids.gclid != nil || ids.gbraid != nil || ids.wbraid != nil || oppref != nil else {
            return false
        }
        // Store first, then force exactly one session below. Calling the public
        // setter here would schedule a second forced session.
        storeGoogleClickIds(gclid: ids.gclid, gbraid: ids.gbraid, wbraid: ids.wbraid)
        let defaults = UserDefaults.standard
        let hasGoogleReference = ids.gclid != nil || ids.gbraid != nil || ids.wbraid != nil
        if oppref != nil && !hasGoogleReference {
            for key in [gclidKey, gbraidKey, wbraidKey, pendingGclidKey, pendingGbraidKey] {
                defaults.removeObject(forKey: key)
            }
        } else if hasGoogleReference && oppref == nil {
            defaults.removeObject(forKey: openAiOpprefKey)
            defaults.removeObject(forKey: pendingOpenAiOpprefKey)
        }
        if let oppref {
            defaults.set(oppref, forKey: openAiOpprefKey)
            defaults.set(oppref, forKey: pendingOpenAiOpprefKey)
        }
        if ids.gclid != nil || ids.gbraid != nil || oppref != nil {
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

    @_spi(Testing) public static func parseOpenAiOppref(from url: URL) -> String? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "oppref" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, value.count <= 1024 else { return nil }
        return value
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
            ]
            appendAppConversionUserAgentContext(to: &body)
            if let country = currentCountryCode() { body["country"] = country }
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                body["app_version"] = version
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

    /// Track the canonical sales funnel used by the app portfolio. TrackHub and
    /// Google App Conversion both support event parameters, so placement stays
    /// in `placement_name`; it is never appended to the event name.
    public static func trackSalesEvent(
        _ event: TrackHubSalesEvent,
        placement: TrackHubSalesPlacement? = nil,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:],
        adAttributionTarget: AdAttributionConversionTarget = .all,
        conversionTag: String? = nil
    ) {
        guard let payload = salesEventPayload(
            event,
            placement: placement,
            callbackParams: callbackParams
        ) else {
            return log("\(event.rawValue) requires a standard placement — skipped")
        }
        trackEvent(
            payload.name,
            callbackParams: payload.callbackParams,
            partnerParams: partnerParams,
            adAttributionTarget: adAttributionTarget,
            conversionTag: conversionTag
        )
    }

    public static func trackOnboardingShown(
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:]
    ) {
        trackSalesEvent(
            .onboardingShown,
            callbackParams: callbackParams,
            partnerParams: partnerParams
        )
    }

    public static func trackPaywallShown(
        at placement: TrackHubSalesPlacement,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:]
    ) {
        trackSalesEvent(
            .paywallShown,
            placement: placement,
            callbackParams: callbackParams,
            partnerParams: partnerParams
        )
    }

    public static func trackPurchaseCtaTapped(
        at placement: TrackHubSalesPlacement,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:]
    ) {
        trackSalesEvent(
            .purchaseCtaTapped,
            placement: placement,
            callbackParams: callbackParams,
            partnerParams: partnerParams
        )
    }

    @_spi(Testing) public static func salesEventPayload(
        _ event: TrackHubSalesEvent,
        placement: TrackHubSalesPlacement?,
        callbackParams: [String: Any] = [:]
    ) -> (name: String, callbackParams: [String: Any])? {
        var params = callbackParams
        // The canonical placement always wins over a caller-supplied free-form
        // value, so dashboards and Google goals never split on spelling drift.
        params.removeValue(forKey: "placement_name")
        switch event {
        case .onboardingShown:
            return (event.rawValue, params)
        case .paywallShown, .purchaseCtaTapped:
            guard let placement else { return nil }
            params["placement_name"] = placement.rawValue
            return (event.rawValue, params)
        }
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
        ]
        appendAppConversionUserAgentContext(to: &body)
        if let productId, !productId.isEmpty { body["product_id"] = productId }
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["app_version"] = v
        }
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
        ]
        appendAppConversionUserAgentContext(to: &body)
        if let country = currentCountryCode() { body["country"] = country }
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = v }
        let defaults = UserDefaults.standard
        if let gclid = defaults.string(forKey: pendingGclidKey) { body["gclid"] = gclid }
        if let gbraid = defaults.string(forKey: pendingGbraidKey) { body["gbraid"] = gbraid }
        if let oppref = defaults.string(forKey: pendingOpenAiOpprefKey) {
            body["oppref"] = oppref
        }
        defaults.removeObject(forKey: pendingGclidKey)
        defaults.removeObject(forKey: pendingGbraidKey)
        defaults.removeObject(forKey: pendingOpenAiOpprefKey)
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        send(path: "sdk/session", body: body) { status in
            if isSuccess(status) { queue.async { fetchAttributionIfNeeded() } }
        }
    }

    private static func handleBackground() { sessionTracker?.background() }

    // MARK: - Install

    private static func reportInstallIfNeeded() {
        guard let config else { return }
        let isIntegrationTest = config.integrationTestToken != nil
        guard isIntegrationTest || !UserDefaults.standard.bool(forKey: installSentKey) else { return }
        guard !attConsentDelayActive else {
            return log("install held until ATT resolves or the first-session timeout expires")
        }
        // sdk_* go inside the signed body so the HMAC authenticates the integration marker too.
        var body: [String: Any] = [
            "user_id": config.userId,
            "install_uid": resolveInstallUid(),
            "sdk_name": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
        ]
        #if os(iOS)
        body["platform"] = "ios"
        #endif
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = v }
        appendAppConversionUserAgentContext(to: &body)
        if let country = currentCountryCode() { body["country"] = country }
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
        if let oppref = UserDefaults.standard.string(forKey: openAiOpprefKey) {
            body["oppref"] = oppref
        }
        // Firebase app_instance_id (GA4 join key for server-confirmed conversions).
        if let aii = UserDefaults.standard.string(forKey: appInstanceIdKey) { body["app_instance_id"] = aii }
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        appendConsent(to: &body)
        send(
            path: "install",
            body: body,
            kind: isIntegrationTest ? "test_install" : "production_install",
            dedupeKey: "install"
        )
    }

    private static func reportPushTokenIfAvailable() {
        guard let config,
              config.integrationTestToken == nil,
              config.sdkSecret?.isEmpty == false,
              !trackingDisabled,
              let token = UserDefaults.standard.string(forKey: pushTokenKey),
              token.count >= 32 else { return }
        let environment = UserDefaults.standard.string(forKey: pushEnvironmentKey)
            ?? TrackHubPushEnvironment.production.rawValue
        let body: [String: Any] = [
            "user_id": config.userId,
            "install_uid": resolveInstallUid(),
            "provider": "apns",
            "environment": environment,
            "token": token,
            "sdk_name": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
        ]
        send(path: "sdk/push-token", body: body)
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
        #if os(iOS) && canImport(AppTrackingTransparency)
        let status = trackingAuthorizationStatus(ATTrackingManager.trackingAuthorizationStatus)
        if status != .unavailable { body["att_status"] = status.rawValue }
        #endif
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        httpClient.data(for: request) { status, data in
            guard let data, status == 200,
                  let fetched = try? JSONDecoder().decode(ConversionSchema.self, from: data) else {
                return log("schema refresh failed — using cached version")
            }
            queue.async {
                schema = fetched
                UserDefaults.standard.set(data, forKey: schemaCacheKey)
                log("schema v\(fetched.schemaVersion) active (\(fetched.rules.count) rules)")
            }
        }
    }

    private static func loadCachedSchema() -> ConversionSchema? {
        guard let data = UserDefaults.standard.data(forKey: schemaCacheKey) else { return nil }
        return try? JSONDecoder().decode(ConversionSchema.self, from: data)
    }

    // MARK: - Attribution + Apphud bridge

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

    private static func attribution(from snapshot: ApphudAttributionSnapshot) -> TrackHubAttribution {
        TrackHubAttribution(
            revision: snapshot.revision,
            status: snapshot.data["status"] ?? "unknown",
            network: snapshot.data["network"] ?? "unknown",
            channel: snapshot.data["channel"] ?? "unknown",
            campaignId: snapshot.data["campaign"],
            adGroupId: snapshot.data["adgroup"],
            keywordId: snapshot.data["keyword"],
            touchpointKind: snapshot.data["touchpoint_kind"],
            source: snapshot.data["attribution_source"],
            data: snapshot.data
        )
    }

    private static func finishAttributionCompletions(_ value: TrackHubAttribution?) {
        let completions = attributionCompletions
        attributionCompletions.removeAll()
        guard !completions.isEmpty else { return }
        DispatchQueue.main.async { completions.forEach { $0(value) } }
    }

    // On `queue`. Only production calls are eligible: Test Lab must not mutate
    // the real attribution/Apphud profile.
    private static func fetchAttributionIfNeeded(
        completion: ((TrackHubAttribution?) -> Void)? = nil
    ) {
        if let completion { attributionCompletions.append(completion) }
        guard !trackingDisabled else {
            finishAttributionCompletions(nil)
            return
        }
        guard !attConsentDelayActive else { return }
        guard !apphudAttributionFetchInFlight else { return }
        guard let config, config.integrationTestToken == nil else {
            finishAttributionCompletions(nil)
            return
        }
        guard let provider = config.backendAttributionProvider else {
            finishAttributionCompletions(nil)
            return log("attribution fetch requires backendAttributionProvider")
        }
        apphudAttributionFetchInFlight = true
        attributionFetchGeneration &+= 1
        let generation = attributionFetchGeneration
        queue.asyncAfter(deadline: .now() + callbackTimeout) {
            guard apphudAttributionFetchInFlight,
                  attributionFetchGeneration == generation else { return }
            apphudAttributionFetchInFlight = false
            finishAttributionCompletions(nil)
            log("backend attribution fetch timed out — will retry")
        }
        DispatchQueue.main.async {
            provider(config.userId) { responseData in
                queue.async {
                    guard apphudAttributionFetchInFlight,
                          attributionFetchGeneration == generation else { return }
                    apphudAttributionFetchInFlight = false
                    guard let responseData,
                          let envelope = try? JSONDecoder().decode(ApphudAttributionEnvelope.self, from: responseData),
                          envelope.ok else {
                        finishAttributionCompletions(nil)
                        log("backend attribution fetch failed — will retry")
                        return
                    }
                    guard let snapshot = envelope.attribution else {
                        finishAttributionCompletions(nil)
                        return
                    }
                    guard snapshot.provider == "custom" else {
                        finishAttributionCompletions(nil)
                        log("backend returned an invalid attribution provider")
                        return
                    }
                    let resolved = attribution(from: snapshot)
                    let changed = currentAttributionSnapshot?.revision != resolved.revision
                    currentAttributionSnapshot = resolved
                    finishAttributionCompletions(resolved)
                    if changed, let handler = config.attributionChangedHandler {
                        DispatchQueue.main.async { handler(resolved) }
                    }
                    guard let handler = config.apphudAttributionHandler,
                          shouldDeliverApphudAttribution(
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
    }

    private static func privacyDisabledKey(token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let suffix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return privacyDisabledKeyPrefix + suffix
    }

    private static func resolveDeferredDeepLinkIfNeeded(
        completion: TrackHubDeferredDeepLinkHandler? = nil
    ) {
        let handler = completion ?? config?.deferredDeepLinkHandler
        guard let handler else { return }
        // The App Store does not provide an Android Install-Referrer-style
        // channel for carrying TrackHub's one-time match capability from the
        // browser into a fresh app install. Never substitute IP/UA correlation
        // as authorization for a user-specific path. Keep the public API
        // source-compatible and fail closed until a deterministic iOS handoff
        // (for example, an approved first-party universal-link flow) exists.
        DispatchQueue.main.async { handler(nil) }
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

    // Persist first, then let one bounded delivery task drain the queue. A slow
    // or unavailable TrackHub endpoint never occupies this state queue and
    // never creates one URLSession task per buffered event.
    private static func send(
        path: String,
        body: [String: Any],
        kind: String? = nil,
        dedupeKey: String? = nil,
        completion: ((Int?) -> Void)? = nil
    ) {
        guard !trackingDisabled else { return }
        var payload = body
        if let testToken = config?.integrationTestToken { payload["test_run_token"] = testToken }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            log("\(path) payload is not JSON-serializable — skipped")
            completion?(nil)
            return
        }
        guard data.count <= maxReportBytes else {
            log("\(path) payload exceeds \(maxReportBytes) bytes — skipped")
            completion?(nil)
            return
        }
        guard let targetQueue = eventQueue else {
            completion?(nil)
            return
        }
        let report = PendingReport(
            path: path,
            body: data,
            kind: kind,
            dedupeKey: dedupeKey
        )
        guard let reportID = targetQueue.enqueue(report) else {
            log("\(path) could not be written to the offline queue — skipped")
            completion?(nil)
            return
        }
        let liveReportIDs = Set(targetQueue.items.map(\.id))
        deliveryCompletions = deliveryCompletions.filter { liveReportIDs.contains($0.key) }
        if let completion { deliveryCompletions[reportID] = completion }
        if attConsentDelayActive {
            log("\(path) buffered during first-session ATT wait")
            return
        }
        flush()
    }

    // Drain exactly one report at a time; each is signed FRESH at send time so
    // a stale timestamp never rejects buffered traffic.
    private static func flush() {
        guard !trackingDisabled else { return }
        guard !attConsentDelayActive else { return }
        guard !deliveryInFlight else { return }
        guard let targetQueue = eventQueue, let report = targetQueue.items.first else { return }

        let notBefore = max(report.nextAttemptAt, transientRetryNotBefore ?? .distantPast)
        if notBefore > Date() {
            scheduleRetry(at: notBefore)
            return
        }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryDeadline = nil
        transientRetryNotBefore = nil
        guard let networkConfig = currentNetworkConfig() else { return }

        deliveryInFlight = true
        postRaw(
            config: networkConfig,
            path: report.path,
            bodyData: report.body
        ) { status in
            queue.async {
                deliveryInFlight = false
                handleDeliveryResult(
                    targetQueue: targetQueue,
                    report: report,
                    status: status
                )
                flush()
            }
        }
    }

    private static func handleDeliveryResult(
        targetQueue: EventQueue,
        report: PendingReport,
        status: Int?
    ) {
        guard targetQueue.items.contains(where: { $0.id == report.id }) else {
            deliveryCompletions.removeValue(forKey: report.id)
            return
        }
        if isRetryable(status) {
            let attempts = report.attempts + 1
            let delay = retryDelay(attempt: attempts, jitter: Double.random(in: 0...1))
            let nextAttemptAt = Date().addingTimeInterval(delay)
            // Keep an in-memory deadline as a fallback if protected storage is
            // temporarily unavailable; this prevents a tight retry loop.
            transientRetryNotBefore = nextAttemptAt
            if !targetQueue.markRetry(
                id: report.id,
                attempts: attempts,
                nextAttemptAt: nextAttemptAt
            ) {
                log("\(report.path) retry state could not be persisted")
            }
            log("\(report.path) delivery failed — retrying with backoff")
            return
        }

        if !targetQueue.remove(id: report.id) {
            log("\(report.path) queue removal could not be persisted")
        }
        let completion = deliveryCompletions.removeValue(forKey: report.id)
        if isSuccess(status) {
            switch report.kind {
            case "production_install":
                UserDefaults.standard.set(true, forKey: installSentKey)
                log("install reported")
                reportConsentUpdate()
                fetchAttributionIfNeeded()
            case "test_install":
                log("integration-test install reported")
            default:
                break
            }
        } else {
            log("\(report.path) rejected with HTTP \(status ?? 0) — not retried")
        }
        completion?(status)
    }

    private static func scheduleRetry(at date: Date) {
        if let current = retryDeadline, current <= date { return }
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            retryWorkItem = nil
            retryDeadline = nil
            flush()
        }
        retryWorkItem = workItem
        retryDeadline = date
        queue.asyncAfter(
            deadline: .now() + max(0, date.timeIntervalSinceNow),
            execute: workItem
        )
    }

    @_spi(Testing) public static func retryDelay(
        attempt: Int,
        jitter: Double
    ) -> TimeInterval {
        let exponent = min(max(0, attempt - 1), 9)
        let cap = min(retryMaxInterval, retryBaseInterval * pow(2, Double(exponent)))
        let unit = min(max(0, jitter.isFinite ? jitter : 0), 1)
        return cap / 2 + (cap / 2 * unit)
    }

    private static func resolveDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let id = "dev_" + UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    private static func resolveInstallUid() -> String {
        if let existing = UserDefaults.standard.string(forKey: installUidKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: installUidKey)
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

    @_spi(Testing) public static func normalizedCountryCode(_ raw: String?) -> String? {
        guard let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            value.count == 2,
            value != "XX",
            value.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 })
        else { return nil }
        return value
    }

    private static func currentCountryCode() -> String? {
        normalizedCountryCode(UserDefaults.standard.string(forKey: countryCodeKey))
    }

    private static func appendAppConversionUserAgentContext(to body: inout [String: Any]) {
        #if os(iOS)
        body["os_version"] = UIDevice.current.systemVersion
        #else
        body["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        body["locale"] = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        if let model = systemValue("hw.machine") { body["device_model"] = model }
        if let build = systemValue("kern.osversion") { body["build"] = build }
    }

    private static func systemValue(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        let result = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
        #else
        return nil
        #endif
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
        guard config?.sdkSecret?.isEmpty == false else { return }
        if let idfa = currentAuthorizedIDFA() {
            body["device_id"] = idfa
            body["device_id_type"] = "idfa"
            body["limit_ad_tracking"] = false
        } else if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            // ID type and LAT are independent in Google's v1.1 contract.
            body["device_id"] = idfv
            body["device_id_type"] = "idfv"
            #if canImport(AppTrackingTransparency)
            body["limit_ad_tracking"] = ATTrackingManager.trackingAuthorizationStatus != .authorized
            #else
            body["limit_ad_tracking"] = false
            #endif
        }
        #endif
    }

    private static func publishApphudDeviceIdentifiers() {
        #if os(iOS)
        guard let handler = config?.apphudDeviceIdentifiersHandler else { return }
        let idfa = currentAuthorizedIDFA()
        let idfv = UIDevice.current.identifierForVendor?.uuidString
        DispatchQueue.main.async { handler(idfa, idfv) }
        #endif
    }

    #if os(iOS) && canImport(AppTrackingTransparency)
    private static func trackingAuthorizationStatus(
        _ status: ATTrackingManager.AuthorizationStatus
    ) -> TrackHubTrackingAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }
    #endif

    private static func currentAuthorizedIDFA() -> String? {
        #if os(iOS) && canImport(AppTrackingTransparency) && canImport(AdSupport)
        guard ATTrackingManager.trackingAuthorizationStatus == .authorized else { return nil }
        let value = ASIdentifierManager.shared().advertisingIdentifier
        guard value != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { return nil }
        return value.uuidString
        #else
        return nil
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

    private static func currentNetworkConfig() -> NetworkConfig? {
        guard let config else { return nil }
        return NetworkConfig(
            endpoint: config.endpoint,
            ingestToken: config.ingestToken,
            sdkSecret: config.sdkSecret
        )
    }

    private static func postRaw(
        config: NetworkConfig,
        path: String,
        bodyData: Data,
        completion: @escaping (Int?) -> Void
    ) {
        let url = config.endpoint.appendingPathComponent("ingest").appendingPathComponent(config.ingestToken).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TrackHub-iOS/\(Self.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData
        if let secret = config.sdkSecret, !secret.isEmpty {
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            let scope = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let message = "\(ts).\(config.ingestToken).\(scope).\(String(data: bodyData, encoding: .utf8) ?? "")"
            let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            request.setValue(ts, forHTTPHeaderField: "X-TrackHub-Timestamp")
            request.setValue("2", forHTTPHeaderField: "X-TrackHub-Signature-Version")
            request.setValue(mac.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-TrackHub-Signature")
        }
        httpClient.data(for: request) { status, _ in completion(status) }
    }

    static func log(_ message: String) {
        if debugLogging { print("[TrackHub] \(message)") }
    }
}
