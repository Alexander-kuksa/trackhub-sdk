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
/// Provider-neutral measurement SDK. Billing SDKs are optional and remain
/// owned by the host application.
public enum AdAttributionConversionTarget: Sendable, Equatable {
    case all
    case install
    case reengagement
}

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

public typealias TrackHubAttributionChangedHandler = @Sendable (TrackHubAttribution) -> Void
public typealias TrackHubDeferredDeepLinkHandler = @Sendable (String?) -> Void

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
    public static let sdkVersion = "3.1.2"

    private static let queue = DispatchQueue(label: "com.trackhub.sdk")
    private static var config: Config?
    private static var schema: ConversionSchema?
    private static var debugLogging = false
    private static var sessionTracker: SessionTracker?
    private static var eventQueue: EventQueue?
    private static var eventQueueNamespace: String?
    private static let httpClient = BoundedHTTPClient()
    private static var deliveryInFlight = false
    private static var retryWorkItem: DispatchWorkItem?
    private static var retryDeadline: Date?
    private static var transientRetryNotBefore: Date?
    // Process-local correction learned from a trusted TrackHub clock-skew
    // response. Queued events are always signed immediately before delivery.
    private static var clockOffsetMilliseconds: Int64 = 0
    private static var deliveryCompletions: [String: (Int?) -> Void] = [:]
    private static var credentialsFailureSignaled = false
    private static var attributionFetchInFlight = false
    private static var attributionFetchGeneration: UInt64 = 0
    private static let privacyStateLock = NSLock()
    private static var privacyStopRequested = false
    private static var privacyErasureInFlight = false
    private static var privacyRetryWorkItem: DispatchWorkItem?
    private static var privacyErasureCompletion: ((Bool) -> Void)?
    private static var currentAttributionSnapshot: TrackHubAttribution?
    // Accessed only on TrackHub.queue. UIKit device values are captured on the
    // main thread before configuration work enters the SDK state machine.
    private static var identifierForVendorSnapshot: String?
    private static var attributionCompletions: [(TrackHubAttribution?) -> Void] = []
    private static var trackingDisabled = false
    private static var attConsentDelayActive = false
    private static var attConsentDelayWorkItem: DispatchWorkItem?
    // The fetch generation outlives the five-second delivery hold. Google may
    // complete later while the independent ATT hold is still active; that
    // valid value must still enrich the buffered install (or, after delivery,
    // be retained for downstream conversions).
    private static var odmDeliveryState = GoogleOdmDeliveryState()
    private static var odmInfoDelayWorkItem: DispatchWorkItem?
    #if os(iOS)
    private static var lifecycleObserver: LifecycleObserver?
    #endif

    struct Config {
        let endpoint: URL
        let trackingEndpoint: URL?
        let ingestToken: String
        let sdkSecret: String?
        let integrationTestToken: String?
        let attConsentWaitingInterval: TimeInterval
        let attributionChangedHandler: TrackHubAttributionChangedHandler?
        let deferredDeepLinkHandler: TrackHubDeferredDeepLinkHandler?
        let deliveryFailureHandler: TrackHubDeliveryFailureHandler?
    }

    private struct NetworkConfig {
        let endpoint: URL
        let ingestToken: String
        let sdkSecret: String?
    }

    private enum NetworkPurpose {
        case measurement
        case trackingEligible
    }

    private static let schemaCacheKey = "trackhub.cv_schema"
    private static let highestInstallFineKey = "trackhub.cv_highest_install_fine"
    private static let highestInstallCoarseKeyPrefix = "trackhub.cv_highest_install_coarse."
    private static let installWindowLockedKeyPrefix = "trackhub.cv_install_window_locked."
    private static let installSentKey = "trackhub.install_sent"
    private static let firstOpenAtKey = "trackhub.first_open_at"
    private static let deviceIdKey = "trackhub.device_id"
    private static let installUidKey = "trackhub.install_uid"
    private static let installCredentialBootstrapKeyPrefix = "trackhub.install_credential_bootstrap."
    private static let pushTokenKey = "trackhub.push_token.apns"
    private static let pushEnvironmentKey = "trackhub.push_environment.apns"
    private static let gclidKey = "trackhub.gclid"
    private static let gbraidKey = "trackhub.gbraid"
    private static let wbraidKey = "trackhub.wbraid"
    private static let pendingGclidKey = "trackhub.pending_gclid"
    private static let pendingGbraidKey = "trackhub.pending_gbraid"
    private static let pendingWbraidKey = "trackhub.pending_wbraid"
    private static let openAiOpprefKey = "trackhub.openai_oppref"
    private static let pendingOpenAiOpprefKey = "trackhub.pending_openai_oppref"
    private static let appInstanceIdKey = "trackhub.app_instance_id"
    private static let odmInfoKey = "trackhub.google_odm_info"
    private static let adUserDataKey = "trackhub.consent.ad_user_data"
    private static let adPersonalizationKey = "trackhub.consent.ad_personalization"
    private static let eeaKey = "trackhub.consent.eea"
    private static let countryCodeKey = "trackhub.country_code"
    // SDK 3.0.2 briefly persisted server-returned geography. 3.0.3 returns
    // geography ownership to the server and removes that retired local state.
    private static let retiredMeasurementGeoKeys = [
        "trackhub.measurement_geo.country.v1",
        "trackhub.measurement_geo.eea.v1",
        "trackhub.measurement_geo.install_uid.v1",
        "trackhub.measurement_geo.refresh_terminal.v1",
    ]
    private static let piplConsentKey = "trackhub.consent.pipl"
    private static let crossBorderTransferConsentKey = "trackhub.consent.cross_border_transfer"
    private static let adsMeasurementConsentKey = "trackhub.consent.ads_measurement"
    private static let adAttributionConversionTagKey = "trackhub.ad_attribution.conversion_tag"
    private static let externalIdentitiesKey = "trackhub.external_identities.v3"
    private static let externalIdentityAckKey = "trackhub.external_identity_ack.v3"
    private static let privacyDisabledKey = "trackhub.privacy_disabled.v2"
    private static let privacyPendingKey = "trackhub.privacy_pending.v2"
    private static let legacyPrivacyDisabledKeyPrefix = "trackhub.privacy_disabled."
    private static let legacyPrivacyPendingKeyPrefix = "trackhub.privacy_pending."
    private static let runtimeCircuitMarkerKey = "trackhub.runtime_circuit.last_run.v1"
    private static let iso8601 = ISO8601DateFormatter()
    private static let callbackTimeout: TimeInterval = 15
    private static let maxOdmInfoWaitingInterval: TimeInterval = 15
    private static let maxReportBytes = EventQueue.defaultMaxItemBytes
    private static let retryBaseInterval: TimeInterval = 1
    private static let retryMaxInterval: TimeInterval = 5 * 60
    private static let runtimeCircuitLock = NSLock()
    private static var runtimeCircuitOpen = false

    private enum RuntimeCircuitReason: String {
        case algorithm
        case storage
        case credentials
    }

    // MARK: - Public API

    /// Start TrackHub once. Billing SDK startup order is irrelevant.
    @MainActor
    public static func start(_ configuration: TrackHubConfig) {
        guard !isRuntimeCircuitOpen() else {
            print("[TrackHub] runtime circuit is open — SDK remains disabled until app restart")
            return
        }
        if case .testLab = configuration.environment,
           configuration.environment.testToken == nil {
            print("[TrackHub] invalid Test Lab token — SDK not started")
            return
        }
        guard let decoded = DecodedTrackHubSdkKey.decode(configuration.sdkKey) else {
            print("[TrackHub] invalid sdkKey — SDK not started")
            return
        }
        let endpoint = decoded.endpoint
        let trackingEndpoint = decoded.trackingEndpoint
        let ingestToken = decoded.ingestToken
        let sdkSecret = decoded.sdkSecret
        // Refuse plaintext HTTP (token in transit + MITM schema poisoning); allow localhost for dev.
        guard endpoint.scheme == "https" || endpoint.host == "localhost" || endpoint.host == "127.0.0.1" else {
            print("[TrackHub] refusing non-HTTPS endpoint \(endpoint) — SDK not started")
            return
        }
        let explicitOdmInfo = boundedOdmInfo(configuration.googleOnDeviceMeasurementInfo)
        let cachedOdmInfo = boundedOdmInfo(UserDefaults.standard.string(forKey: odmInfoKey))
        let provider = configuration.googleOnDeviceMeasurementInfoProvider
        let resultProvider = configuration.googleOnDeviceMeasurementResultProvider
        let shouldFetchOdmInfo = shouldFetchGoogleOnDeviceMeasurementInfo(
            hasProvider: provider != nil || resultProvider != nil,
            hasExplicitInfo: explicitOdmInfo != nil,
            hasCachedInfo: cachedOdmInfo != nil,
            installAlreadySent: UserDefaults.standard.bool(forKey: installSentKey),
            privacyStopped: isPrivacyStopRequested()
                || UserDefaults.standard.bool(forKey: privacyDisabledKey)
                || hasPendingErasureState()
        )
        let requestedOdmFetchToken = shouldFetchOdmInfo ? UUID() : nil
        // Do not recreate measurement state merely because start() was called
        // after a durable privacy stop. The value is consumed only when the
        // provider is actually eligible to run.
        let firstOpenAt = shouldFetchOdmInfo ? resolveFirstOpenAt() : Date()
        // A failed durable first-open write opens the process-local storage
        // circuit. Do not invoke a third-party binary after measurement has
        // been disabled for this process.
        let odmFetchToken = isRuntimeCircuitOpen() ? nil : requestedOdmFetchToken
        let applyConfiguration: (String?) -> Void = { capturedIdfv in
          queue.async {
            identifierForVendorSnapshot = capturedIdfv
            config = Config(
                endpoint: endpoint,
                trackingEndpoint: trackingEndpoint,
                ingestToken: ingestToken,
                sdkSecret: sdkSecret,
                integrationTestToken: configuration.environment.testToken,
                attConsentWaitingInterval: normalizedATTConsentWaitingInterval(configuration.attConsentWaitingInterval),
                attributionChangedHandler: configuration.attributionChangedHandler,
                deferredDeepLinkHandler: configuration.deferredDeepLinkHandler,
                deliveryFailureHandler: configuration.deliveryFailureHandler
            )
            credentialsFailureSignaled = false
            persistGoogleAdsConsent(configuration.googleAdsConsent)
            persistPIPLConsent(configuration.piplConsent)
            if let country = normalizedCountryCode(configuration.countryCode) {
                UserDefaults.standard.set(country, forKey: countryCodeKey)
            }
            purgeRetiredMeasurementGeographyState()
            migrateLegacyPrivacyState()
            var pendingPrivacyErasure = loadPendingErasure()
            let persistedPrivacyStop = UserDefaults.standard.bool(forKey: privacyDisabledKey)
            // Recover the narrow crash window between persisting the local
            // stop and committing its erasure job. A confirmed erasure has
            // already removed installUid, so it is not recreated.
            if persistedPrivacyStop, pendingPrivacyErasure == nil,
               let retainedInstallUid = InstallIdentityStore.loadExisting(
                    legacyKey: installUidKey
               ),
               !retainedInstallUid.isEmpty,
               persistPendingErasure(
                    installUid: retainedInstallUid,
                    reason: "user_requested"
               ) {
                pendingPrivacyErasure = loadPendingErasure()
            }
            let pendingPrivacyStateExists = hasPendingErasureState()
            privacyStateLock.lock()
            privacyStopRequested = privacyStopRequested
                || persistedPrivacyStop
                || pendingPrivacyStateExists
            privacyStateLock.unlock()
            trackingDisabled = privacyStopRequested
            debugLogging = configuration.debugLogging
            // Load the durable queue before the privacy gate: if the process
            // crashed immediately after gdprForgetMe(), the next launch must
            // still remove already-buffered reports before any retry.
            let namespace = offlineQueueNamespace(
                for: config?.integrationTestToken,
                ingestToken: ingestToken
            )
            if eventQueue == nil || eventQueueNamespace != namespace {
                eventQueue = EventQueue(url: queueFileURL(
                    testToken: config?.integrationTestToken,
                    ingestToken: ingestToken
                ))
                eventQueueNamespace = namespace
            }
            // Retire an upgrade-refresh report queued by SDK 3.0.2 without
            // making another install request. Normal install reports remain.
            eventQueue?.items
                .filter { $0.kind == "install_geo_refresh" }
                .forEach { _ = eventQueue?.remove(id: $0.id) }
            if trackingDisabled {
                log("tracking disabled after a privacy erasure request")
                stopAndClearLocalMeasurement(retainingInstallUid: pendingPrivacyErasure?.installUid)
                // Register lifecycle observation without starting network work
                // inside this configuration turn. If gdprForgetMe raced start,
                // its already-enqueued state block must install the completion
                // before the erasure can finish.
                startSessionTracking(beginForeground: false)
                queue.async { retryPendingErasure() }
                return
            }
            if let aii = configuration.firebaseAppInstanceId, !aii.isEmpty {
                UserDefaults.standard.set(aii, forKey: appInstanceIdKey)
            }
            if let info = explicitOdmInfo {
                UserDefaults.standard.set(info, forKey: odmInfoKey)
            }
            startGoogleOnDeviceMeasurementDelayIfNeeded(
                token: odmFetchToken,
                waitingInterval: configuration.googleOnDeviceMeasurementTimeout
            )
            schema = loadCachedSchema()
            sessionTracker = sessionTracker ?? SessionTracker()
            // Test Lab reports must never drain the production offline queue.
            // Keep the same in-memory instance for repeated start calls in
            // one namespace so a stale instance cannot overwrite newer state.
            retryWorkItem?.cancel()
            retryWorkItem = nil
            retryDeadline = nil
            transientRetryNotBefore = nil
            startATTConsentDelayIfNeeded()
            reportRuntimeCircuitDiagnosticIfNeeded()
            if config?.integrationTestToken == nil {
                SKANUpdater.registerForAttribution()
                applyLocalInstallConversionRule()
            }
            reportInstallIfNeeded()
            syncPersistedExternalIdentities()
            reportPushTokenIfAvailable()
            fetchAttributionIfNeeded()
            resolveDeferredDeepLinkIfNeeded()
            refreshSchema()
            startSessionTracking()
            flush()
          }
        }
        // Capture UIKit state before returning so calls immediately following
        // start() are ordered behind configuration on the serial state queue.
        #if os(iOS)
        applyConfiguration(UIDevice.current.identifierForVendor?.uuidString)
        #else
        applyConfiguration(nil)
        #endif
        if let odmFetchToken {
            // start(_:) is @MainActor, so provider SDKs with main-thread APIs
            // can be called without dispatching or blocking the host UI.
            let completion: @Sendable (TrackHubGoogleOdmResult) -> Void = { result in
                queue.async {
                    completeGoogleOnDeviceMeasurementFetch(
                        token: odmFetchToken,
                        result: result
                    )
                }
            }
            if let resultProvider {
                resultProvider(firstOpenAt, completion)
            } else if let provider {
                provider(firstOpenAt) { completion(.fromProvider(info: $0, error: nil)) }
            }
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
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        let value = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 32, value.count <= 4096 else { return }
        UserDefaults.standard.set(value, forKey: pushTokenKey)
        UserDefaults.standard.set(environment.rawValue, forKey: pushEnvironmentKey)
        queue.async { reportPushTokenIfAvailable() }
    }

    /// Bind or clear an optional billing identity without importing that
    /// provider's SDK. Apphud, RevenueCat and custom providers are independent.
    /// Safe to call immediately after `start`; the desired value is durable,
    /// while network delivery waits until the production install is accepted.
    public static func setExternalIdentity(provider: String, userId: String?) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen(),
              let provider = normalizedExternalProvider(provider) else { return }
        let value = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == nil || (value?.isEmpty == false && value!.utf8.count <= 256) else { return }
        var desired = UserDefaults.standard.dictionary(forKey: externalIdentitiesKey)
            as? [String: String] ?? [:]
        desired[provider] = value ?? ""
        UserDefaults.standard.set(desired, forKey: externalIdentitiesKey)
        queue.async { syncExternalIdentity(provider: provider, userId: value) }
    }

    /// Returns the durable TrackHub attribution snapshot. The completion is
    /// always delivered on the main queue. A network refresh is made when the
    /// current process has not fetched a snapshot yet.
    public static func attribution(
        completion: @escaping (TrackHubAttribution?) -> Void
    ) {
        guard !isRuntimeCircuitOpen() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
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
        guard !isRuntimeCircuitOpen() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async { resolveDeferredDeepLinkIfNeeded(completion: completion) }
    }

    /// Immediately stops local tracking and durably schedules erasure of this
    /// installation. Offline/server failures are retried on launch/foreground;
    /// tracking never resumes because a network request failed.
    public static func gdprForgetMe(
        reason: String = "user_requested",
        completion: ((Bool) -> Void)? = nil
    ) {
        privacyStateLock.lock()
        privacyStopRequested = true
        privacyStateLock.unlock()
        let boundedReason = String(reason.prefix(256))
        // The privacy state belongs to this app installation, not to a
        // rotatable SDK key. Persist it before consulting runtime config so a
        // call made before start() is still crash-safe.
        if UserDefaults.standard.bool(forKey: privacyDisabledKey),
           !hasPendingErasureState(),
           InstallIdentityStore.loadExisting(legacyKey: installUidKey) == nil {
            DispatchQueue.main.async { completion?(true) }
            return
        }
        let preparedInstallUid = loadPendingErasure()?.installUid ?? resolveInstallUid()
        UserDefaults.standard.set(true, forKey: privacyDisabledKey)
        _ = UserDefaults.standard.synchronize()
        let preparedDurably = loadPendingErasure() != nil || persistPendingErasure(
            installUid: preparedInstallUid,
            reason: boundedReason
        )
        queue.async {
            guard config != nil else {
                trackingDisabled = true
                stopAndClearLocalMeasurement(retainingInstallUid: preparedInstallUid)
                if preparedDurably {
                    addPrivacyErasureCompletion(completion)
                } else {
                    DispatchQueue.main.async { completion?(false) }
                }
                return
            }
            trackingDisabled = true
            UserDefaults.standard.set(true, forKey: privacyDisabledKey)
            _ = UserDefaults.standard.synchronize()
            if loadPendingErasure() == nil {
                _ = persistPendingErasure(
                    installUid: preparedInstallUid,
                    reason: boundedReason
                )
            }
            stopAndClearLocalMeasurement(retainingInstallUid: preparedInstallUid)
            guard loadPendingErasure() != nil else {
                let callback = privacyErasureCompletion
                privacyErasureCompletion = nil
                DispatchQueue.main.async { callback?(false) }
                return DispatchQueue.main.async { completion?(false) }
            }
            addPrivacyErasureCompletion(completion)
            retryPendingErasure()
        }
    }

    /// Present Apple's ATT prompt. Call this only after the app's contextual
    /// explanation, at the product-appropriate moment. It is intentionally not
    /// shown automatically from `start`, because launch-time permission
    /// prompts produce poor consent quality and make onboarding brittle.
    ///
    /// `NSUserTrackingUsageDescription` must be present in the host app's
    /// Info.plist. IDFV is available regardless of the result; IDFA is exposed
    /// to TrackHub only after `.authorized`.
    public static func requestAppTrackingTransparency(
        completion: ((TrackHubTrackingAuthorizationStatus) -> Void)? = nil
    ) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else {
            DispatchQueue.main.async { completion?(.unavailable) }
            return
        }
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

    /// Bounded first-session wait. It defaults to 120 seconds and is capped at
    /// 360 seconds. Set it to zero only when the host intentionally does not
    /// run an ATT flow. Only TrackHub's first install/session/event delivery
    /// waits for ATT or the timeout.
    @_spi(Testing) public static func normalizedATTConsentWaitingInterval(
        _ value: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, 360)
    }

    /// Remaining process-independent ATT hold. The deadline is anchored to
    /// the durable first-open timestamp, so repeated hard kills cannot restart
    /// a fresh 120-second wait forever.
    @_spi(Testing) public static func remainingATTConsentWaitingInterval(
        waitingInterval: TimeInterval,
        firstOpenAt: Date,
        now: Date
    ) -> TimeInterval {
        let bounded = normalizedATTConsentWaitingInterval(waitingInterval)
        guard bounded > 0 else { return 0 }
        return min(bounded, max(0, firstOpenAt.addingTimeInterval(bounded).timeIntervalSince(now)))
    }

    @_spi(Testing) public static func normalizedGoogleOnDeviceMeasurementWaitingInterval(
        _ value: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, maxOdmInfoWaitingInterval)
    }

    @_spi(Testing) public static func shouldFetchGoogleOnDeviceMeasurementInfo(
        hasProvider: Bool,
        hasExplicitInfo: Bool,
        hasCachedInfo: Bool,
        installAlreadySent: Bool,
        privacyStopped: Bool
    ) -> Bool {
        hasProvider && !hasExplicitInfo && !hasCachedInfo && !installAlreadySent && !privacyStopped
    }

    private static var firstOpenDeliveryDelayActive: Bool {
        attConsentDelayActive || odmDeliveryState.deliveryDelayActive
    }

    // On `queue`. Only delivery is delayed: public APIs remain non-blocking and
    // their reports continue entering the existing durable queue.
    private static func startGoogleOnDeviceMeasurementDelayIfNeeded(
        token: UUID?,
        waitingInterval: TimeInterval
    ) {
        odmInfoDelayWorkItem?.cancel()
        odmInfoDelayWorkItem = nil
        let interval = normalizedGoogleOnDeviceMeasurementWaitingInterval(waitingInterval)
        odmDeliveryState.start(token: token, delayDelivery: interval > 0)
        guard let token, interval > 0 else { return }
        let workItem = DispatchWorkItem {
            expireGoogleOnDeviceMeasurementDelay(token: token, interval: interval)
        }
        odmInfoDelayWorkItem = workItem
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
        log("first-open delivery waiting up to \(Int(interval))s for Google ODM")
    }

    // On `queue`. The timeout releases delivery but deliberately keeps the
    // fetch generation alive: a later provider callback can still enrich an
    // install held by ATT and is useful for downstream conversions even when
    // the first-open report has already left the device.
    private static func expireGoogleOnDeviceMeasurementDelay(
        token: UUID,
        interval: TimeInterval
    ) {
        guard odmDeliveryState.expire(token: token) else { return }
        odmInfoDelayWorkItem?.cancel()
        odmInfoDelayWorkItem = nil
        log("first-open Google ODM wait ended (timeout after \(Int(interval))s)")
        reportGoogleOdmDiagnostic(reason: "odm_timeout", token: token, phase: "timeout")
        flush()
    }

    // On `queue`. A stale generation, privacy erasure or runtime circuit makes
    // the callback inert. Provider completion and timeout may race safely.
    private static func completeGoogleOnDeviceMeasurementFetch(
        token: UUID,
        result: TrackHubGoogleOdmResult
    ) {
        let value = result.info
        let outcome = odmDeliveryState.complete(
            token: token,
            privacyStopped: trackingDisabled || isPrivacyStopRequested(),
            runtimeCircuitOpen: isRuntimeCircuitOpen(),
            hasValidInfo: value != nil
        )
        guard case let .completed(cacheAndRefreshInstall, releasedDeliveryHold) = outcome else {
            return
        }
        if cacheAndRefreshInstall, let value {
            UserDefaults.standard.set(value, forKey: odmInfoKey)
            // Replace a still-buffered install body at the same durable queue
            // position. If first_open already left after the ODM timeout, the
            // cached value remains available to downstream conversions.
            reportInstallIfNeeded()
        }
        if releasedDeliveryHold {
            odmInfoDelayWorkItem?.cancel()
            odmInfoDelayWorkItem = nil
        }
        log("first-open Google ODM provider completed (\(value == nil ? "no info" : "info cached"))")
        reportGoogleOdmDiagnostic(reason: result.diagnosticReason, token: token, phase: "completion")
        flush()
    }

    /// At most one timeout and one completion per fetch generation. Uses the
    /// existing signed, bounded diagnostic queue; no install/user ID, ODM blob,
    /// error text, URL or advertising ID is included. Not a Google conversion.
    private static func reportGoogleOdmDiagnostic(reason: String, token: UUID, phase: String) {
        guard config != nil, config?.integrationTestToken == nil,
              firstOpenSignalEnrichmentAllowed() else { return }
        _ = send(path: "sdk/diagnostic", body: [
            "id": UUID().uuidString.lowercased(), "sdk_source": "trackhub-ios",
            "sdk_version": Self.sdkVersion, "reason": reason,
            "occurred_at": iso8601.string(from: Date()),
        ], kind: "sdk_odm_diagnostic", dedupeKey: "sdk_odm:\(token):\(phase)")
    }

    @_spi(Testing) public static func shouldAcceptGoogleOnDeviceMeasurementInfo(
        hasMatchingGeneration: Bool,
        privacyStopped: Bool,
        runtimeCircuitOpen: Bool,
        hasValidInfo: Bool
    ) -> Bool {
        hasMatchingGeneration && !privacyStopped && !runtimeCircuitOpen && hasValidInfo
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

        let interval = remainingATTConsentWaitingInterval(
            waitingInterval: config.attConsentWaitingInterval,
            firstOpenAt: resolveFirstOpenAt(),
            now: Date()
        )
        guard interval > 0 else {
            return log("first-session ATT wait deadline already elapsed")
        }
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
    /// Firebase — the host app passes the id in. Prefer setting it on
    /// `TrackHubConfig` before `start`; later updates re-report install context.
    public static func updateFirebaseAppInstanceId(_ appInstanceId: String) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        guard !appInstanceId.isEmpty else { return }
        UserDefaults.standard.set(appInstanceId, forKey: appInstanceIdKey)
    }

    /// Provide the opaque `aggregateConversionInfo` produced by Google's
    /// standalone GoogleAdsOnDeviceConversion SDK on iOS. This is NOT Firebase.
    /// Call before `start(...)` (or pass it through
    /// `googleOnDeviceMeasurementInfo`) so the first_open request can carry
    /// `odm_info`; TrackHub caches it for later sessions and purchases.
    public static func updateGoogleOnDeviceMeasurementInfo(_ info: String) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        guard let value = boundedOdmInfo(info) else { return }
        UserDefaults.standard.set(value, forKey: odmInfoKey)
    }

    /// Set the actual ISO-3166 country where measurement originates. Do not
    /// derive this from the device language/Locale: a user can travel or choose
    /// a language unrelated to their current country. A trusted server edge may
    /// override this value from its geo header.
    public static func updateCountryCode(_ countryCode: String) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        guard let value = normalizedCountryCode(countryCode) else { return }
        UserDefaults.standard.set(value, forKey: countryCodeKey)
    }

    /// Stable first-launch timestamp for Google's standalone on-device
    /// measurement SDK. Safe to read before `start(...)`.
    public static var firstOpenAt: Date { resolveFirstOpenAt() }

    /// Consent Mode signals used by App Conversion. Set them before start and
    /// update whenever consent changes. A post-start change re-reports only the
    /// install identity + latest consent; attribution stays first-write-wins.
    public static func updateGoogleAdsConsent(_ consent: TrackHubGoogleAdsConsent) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        persistGoogleAdsConsent(consent)
        queue.async { reportConsentUpdateIfInstalled() }
    }

    /// Mainland-China PIPL signals. Call after your consent UI resolves them.
    /// TrackHub fails closed for Google cross-border ads measurement once these
    /// signals are in use and transfer/measurement consent is not granted.
    public static func updatePIPLConsent(_ consent: TrackHubPIPLConsent) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        persistPIPLConsent(consent)
        queue.async { reportConsentUpdateIfInstalled() }
    }

    private static func persistGoogleAdsConsent(_ consent: TrackHubGoogleAdsConsent) {
        let defaults = UserDefaults.standard
        if let value = consent.adUserData.boolValue { defaults.set(value, forKey: adUserDataKey) }
        else { defaults.removeObject(forKey: adUserDataKey) }
        if let value = consent.adPersonalization.boolValue { defaults.set(value, forKey: adPersonalizationKey) }
        else { defaults.removeObject(forKey: adPersonalizationKey) }
        if let value = consent.isEea { defaults.set(value, forKey: eeaKey) }
        else { defaults.removeObject(forKey: eeaKey) }
    }

    private static func persistPIPLConsent(_ consent: TrackHubPIPLConsent) {
        let defaults = UserDefaults.standard
        if let value = consent.personalInformation.boolValue { defaults.set(value, forKey: piplConsentKey) }
        else { defaults.removeObject(forKey: piplConsentKey) }
        if let value = consent.crossBorderTransfer.boolValue { defaults.set(value, forKey: crossBorderTransferConsentKey) }
        else { defaults.removeObject(forKey: crossBorderTransferConsentKey) }
        if let value = consent.adsMeasurement.boolValue { defaults.set(value, forKey: adsMeasurementConsentKey) }
        else { defaults.removeObject(forKey: adsMeasurementConsentKey) }
    }

    /// Record Google click identifiers captured from an app/universal link.
    /// `gclid`, `gbraid`, and `wbraid` are attached to the corresponding session_start;
    /// install-time values also ride the one-shot install report. `wbraid` is
    /// retained for the separate web/offline conversion contour.
    public static func setGoogleClickIds(gclid: String? = nil, gbraid: String? = nil, wbraid: String? = nil) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        storeGoogleClickIds(gclid: gclid, gbraid: gbraid, wbraid: wbraid)
        if !sessionGoogleClickIds(gclid: gclid, gbraid: gbraid, wbraid: wbraid).isEmpty {
            queue.async {
                if config != nil { handleForeground(force: true) }
            }
        }
    }

    @_spi(Testing) public static func storeGoogleClickIds(
        gclid: String?,
        gbraid: String?,
        wbraid: String?
    ) {
        if let c = gclid, !c.isEmpty {
            UserDefaults.standard.set(c, forKey: gclidKey)
            UserDefaults.standard.set(c, forKey: pendingGclidKey)
        }
        if let g = gbraid, !g.isEmpty { UserDefaults.standard.set(g, forKey: gbraidKey) }
        if let g = gbraid, !g.isEmpty { UserDefaults.standard.set(g, forKey: pendingGbraidKey) }
        if let w = wbraid, !w.isEmpty {
            UserDefaults.standard.set(w, forKey: wbraidKey)
            UserDefaults.standard.set(w, forKey: pendingWbraidKey)
        }
    }

    /// The exact Google click references that belong on a session payload.
    /// Kept pure so the one-shot wire contract is covered without network I/O.
    @_spi(Testing) public static func sessionGoogleClickIds(
        gclid: String?,
        gbraid: String?,
        wbraid: String?
    ) -> [String: String] {
        var result: [String: String] = [:]
        if let gclid, !gclid.isEmpty { result["gclid"] = gclid }
        if let gbraid, !gbraid.isEmpty { result["gbraid"] = gbraid }
        if let wbraid, !wbraid.isEmpty { result["wbraid"] = wbraid }
        return result
    }

    /// Captures supported ad click references from a deep/universal link:
    /// Google `gclid`/`gbraid`/`wbraid` and OpenAI Ads `oppref`.
    @discardableResult
    public static func handleDeepLink(_ url: URL) -> Bool {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return false }
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
            for key in [
                gclidKey, gbraidKey, wbraidKey,
                pendingGclidKey, pendingGbraidKey, pendingWbraidKey,
            ] {
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
        if !sessionGoogleClickIds(
            gclid: ids.gclid,
            gbraid: ids.gbraid,
            wbraid: ids.wbraid
        ).isEmpty || oppref != nil {
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
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return nil }
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
        // `oppref` is an opaque OpenAI capability. URLComponents.queryItems
        // percent-decodes values, so read the percent-encoded query directly
        // and preserve the exact value that arrived in the deep link.
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        let value = query?
            .split(separator: "&", omittingEmptySubsequences: false)
            .compactMap { item -> String? in
                guard let separator = item.firstIndex(of: "=") else { return nil }
                guard item[..<separator] == "oppref" else { return nil }
                return String(item[item.index(after: separator)...])
            }
            .first
        guard let value, !value.isEmpty, value.count <= 1024 else { return nil }
        return value
    }

    /// Tracks a non-financial engagement event → TrackHub analytics and applies
    /// the SKAN conversion value when the active schema has a matching rule.
    /// Purchases use `trackPurchaseObserved`; billing remains server-sourced.
    @_spi(Testing) public static func deduplicatedClientEventId(
        installUid: String,
        eventName: String,
        deduplicationId: String
    ) -> String? {
        let normalizedEventName = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = deduplicationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEventName.isEmpty,
              !normalized.isEmpty,
              normalized.utf8.count <= 256 else { return nil }
        let material = Data("\(installUid)\u{0}\(normalizedEventName)\u{0}\(normalized)".utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "dedup1-\(digest)"
    }

    public static func trackEvent(
        _ name: String,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:],
        adAttributionTarget: AdAttributionConversionTarget = .all,
        conversionTag: String? = nil,
        deduplicationId: String? = nil
    ) {
        guard !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        let normalizedDeduplicationId = deduplicationId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDeduplicationId,
           !normalizedDeduplicationId.isEmpty,
           normalizedDeduplicationId.utf8.count > 256 {
            return log("trackEvent deduplicationId exceeds 256 UTF-8 bytes — skipped")
        }
        queue.async {
            guard !isRuntimeCircuitOpen() else { return }
            guard config != nil else { return log("trackEvent(\(name)) before start — skipped") }
            let installUid = resolveInstallUid()
            let clientEventId = normalizedDeduplicationId.flatMap {
                deduplicatedClientEventId(
                    installUid: installUid,
                    eventName: normalizedName,
                    deduplicationId: $0
                )
            } ?? UUID().uuidString
            var body: [String: Any] = [
                "client_event_id": clientEventId,
                "event_name": normalizedName,
                "user_id": installUid,
                "install_uid": installUid,
                "occurred_at": iso8601.string(from: Date()),
                "first_open_at": iso8601.string(from: resolveFirstOpenAt()),
                "sdk_version": Self.sdkVersion,
                "sdk_source": "trackhub-ios",
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
            normalizedName,
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
        conversionTag: String? = nil,
        deduplicationId: String? = nil
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
            conversionTag: conversionTag,
            deduplicationId: deduplicationId
        )
    }

    public static func trackOnboardingShown(
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:],
        deduplicationId: String? = nil
    ) {
        trackSalesEvent(
            .onboardingShown,
            callbackParams: callbackParams,
            partnerParams: partnerParams,
            deduplicationId: deduplicationId
        )
    }

    public static func trackPaywallShown(
        at placement: TrackHubSalesPlacement,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:],
        deduplicationId: String? = nil
    ) {
        trackSalesEvent(
            .paywallShown,
            placement: placement,
            callbackParams: callbackParams,
            partnerParams: partnerParams,
            deduplicationId: deduplicationId
        )
    }

    public static func trackPurchaseCtaTapped(
        at placement: TrackHubSalesPlacement,
        callbackParams: [String: Any] = [:],
        partnerParams: [String: Any] = [:],
        deduplicationId: String? = nil
    ) {
        trackSalesEvent(
            .purchaseCtaTapped,
            placement: placement,
            callbackParams: callbackParams,
            partnerParams: partnerParams,
            deduplicationId: deduplicationId
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
    /// Conversion API. No money is accepted here: the matching billing webhook
    /// supplies value/currency. `transactionId` must be the stable store
    /// transaction id the billing source sends. Requires `sdkSecret` because the
    /// server rejects unsigned purchase contexts.
    public static func trackPurchaseObserved(transactionId: String, productId: String? = nil) {
        guard !transactionId.isEmpty,
              !isPrivacyStopRequested(),
              !isRuntimeCircuitOpen() else { return }
        queue.async {
            guard !isRuntimeCircuitOpen() else { return }
            guard let config else { return log("trackPurchaseObserved before start — skipped") }
            guard config.sdkSecret?.isEmpty == false else {
                return log("trackPurchaseObserved requires sdkSecret — skipped")
            }
            send(
                path: "sdk/purchase-context",
                body: purchaseContextBody(
                    transactionId: transactionId,
                    productId: productId
                ),
                kind: "transaction_context",
                dedupeKey: "transaction_context:\(transactionId)"
            )
        }
    }

    #if canImport(StoreKit)
    /// StoreKit 2 convenience overload. Pass the verified transaction surfaced
    /// by the host app's successful purchase flow.
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
        occurredAt: Date = Date(),
        firstOpenAt: Date? = nil
    ) -> [String: Any] {
        let installUid = resolveInstallUid()
        var body: [String: Any] = [
            "transaction_id": transactionId,
            "user_id": installUid,
            "install_uid": installUid,
            "occurred_at": iso8601.string(from: occurredAt),
            "first_open_at": iso8601.string(from: firstOpenAt ?? resolveFirstOpenAt()),
            "sdk_version": Self.sdkVersion,
            "sdk_source": "trackhub-ios",
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
    private static func track(
        _ event: String,
        revenueCents: Int? = nil,
        adAttributionTarget: AdAttributionConversionTarget = .all,
        conversionTag: String? = nil
    ) {
        queue.async {
            guard !isRuntimeCircuitOpen() else { return }
            guard config?.integrationTestToken == nil else {
                return log("Apple conversion update suppressed in Integration Test Lab")
            }
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
            let safeUpdate: ConversionUpdate
            if adAttributionTarget == .reengagement {
                safeUpdate = update
            } else if let window = currentInstallConversionWindow() {
                safeUpdate = monotonicInstallConversionUpdate(update, window: window)
            } else {
                safeUpdate = update
            }
            SKANUpdater.apply(
                safeUpdate,
                adAttributionTarget: adAttributionTarget,
                conversionTag: resolvedTag
            )
        }
    }

    // MARK: - Sessions

    private static func startSessionTracking(beginForeground: Bool = true) {
        #if os(iOS)
        if lifecycleObserver == nil {
            lifecycleObserver = LifecycleObserver(
                onForeground: { queue.async { handleForeground() } },
                onBackground: { queue.async { handleBackground() } }
            )
        }
        if beginForeground { handleForeground() } // the launch foreground
        #endif
    }

    // On `queue`. Reports a new session if this foreground started one.
    private static func handleForeground(force: Bool = false) {
        guard !isRuntimeCircuitOpen() else { return }
        if trackingDisabled || isPrivacyStopRequested() {
            retryPendingErasure()
            return
        }
        guard config != nil, let tracker = sessionTracker else { return }
        let started: SessionStart?
        if force {
            started = tracker.forceForeground()
        } else {
            started = tracker.foreground()
        }
        guard let started else { return }
        let installUid = resolveInstallUid()
        var body: [String: Any] = [
            "user_id": installUid,
            "install_uid": installUid,
            "session_uid": started.sessionUid,
            "session_num": started.sessionNum,
            "started_at": iso8601.string(from: started.startedAt),
            "first_open_at": iso8601.string(from: resolveFirstOpenAt()),
            "sdk_version": Self.sdkVersion,
            "sdk_source": "trackhub-ios",
        ]
        appendAppConversionUserAgentContext(to: &body)
        if let country = currentCountryCode() { body["country"] = country }
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { body["app_version"] = v }
        let defaults = UserDefaults.standard
        for (key, value) in sessionGoogleClickIds(
            gclid: defaults.string(forKey: pendingGclidKey),
            gbraid: defaults.string(forKey: pendingGbraidKey),
            wbraid: defaults.string(forKey: pendingWbraidKey)
        ) {
            body[key] = value
        }
        if let oppref = defaults.string(forKey: pendingOpenAiOpprefKey) {
            body["oppref"] = oppref
        }
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        let accepted = send(path: "sdk/session", body: body) { status in
            if isSuccess(status) { queue.async { fetchAttributionIfNeeded() } }
        }
        if accepted {
            // Attribution references are one-shot, but only after the exact
            // session payload is durable. A full or temporarily unavailable
            // queue must not turn an enqueue failure into permanent loss.
            defaults.removeObject(forKey: pendingGclidKey)
            defaults.removeObject(forKey: pendingGbraidKey)
            defaults.removeObject(forKey: pendingWbraidKey)
            defaults.removeObject(forKey: pendingOpenAiOpprefKey)
        }
    }

    private static func handleBackground() { sessionTracker?.background() }

    // MARK: - Install

    private static func reportInstallIfNeeded() {
        guard !isRuntimeCircuitOpen() else { return }
        guard let config else { return }
        let isIntegrationTest = config.integrationTestToken != nil
        let defaults = UserDefaults.standard
        let installUid = resolveInstallUid()
        let installAlreadySent = defaults.bool(forKey: installSentKey)
        let hasCredential = InstallCredentialStore.load(
            ingestToken: config.ingestToken,
            installUid: installUid
        ) != nil
        let bootstrapKey = installCredentialBootstrapKey(token: config.ingestToken)
        if !isIntegrationTest && !shouldReportInstallForCredential(
            installAlreadySent: installAlreadySent,
            hasCredential: hasCredential,
            lastAttempt: defaults.double(forKey: bootstrapKey),
            now: Date().timeIntervalSince1970
        ) {
            return
        }
        guard !attConsentDelayActive else {
            return log("install held until ATT resolves or the first-session timeout expires")
        }
        let body = installContextBody(installUid: installUid)
        let accepted = send(
            path: "install",
            body: body,
            kind: isIntegrationTest ? "test_install" : "production_install",
            dedupeKey: "install"
        )
        if accepted && !isIntegrationTest {
            defaults.set(Date().timeIntervalSince1970, forKey: bootstrapKey)
        }
    }

    private static func installContextBody(installUid: String) -> [String: Any] {
        // sdk_* stay inside the signed body so the HMAC authenticates the
        // integration marker too.
        var body: [String: Any] = [
            "user_id": installUid,
            "install_uid": installUid,
            "sdk_name": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
            "occurred_at": iso8601.string(from: resolveFirstOpenAt()),
        ]
        #if os(iOS)
        body["platform"] = "ios"
        #endif
        if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["app_version"] = value
        }
        appendAppConversionUserAgentContext(to: &body)
        if let country = currentCountryCode() { body["country"] = country }
        // Google click ids captured from a deep link (set via setGoogleClickId /
        // handleDeepLink before start) — the iOS path for user-level Google
        // attribution + conversion return.
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: gclidKey) { body["gclid"] = value }
        if let value = defaults.string(forKey: gbraidKey) { body["gbraid"] = value }
        if let value = defaults.string(forKey: wbraidKey) { body["wbraid"] = value }
        if let value = defaults.string(forKey: openAiOpprefKey) { body["oppref"] = value }
        if let value = defaults.string(forKey: appInstanceIdKey) { body["app_instance_id"] = value }
        appendOdmInfo(to: &body)
        appendAppConversionDeviceIdentifier(to: &body)
        appendConsent(to: &body)
        return body
    }

    private static func reportPushTokenIfAvailable() {
        guard !isRuntimeCircuitOpen() else { return }
        guard let config,
              config.integrationTestToken == nil,
              config.sdkSecret?.isEmpty == false,
              !trackingDisabled,
              let token = UserDefaults.standard.string(forKey: pushTokenKey),
              token.count >= 32 else { return }
        let environment = UserDefaults.standard.string(forKey: pushEnvironmentKey)
            ?? TrackHubPushEnvironment.production.rawValue
        let installUid = resolveInstallUid()
        let body: [String: Any] = [
            "user_id": installUid,
            "install_uid": installUid,
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
        if defaults.object(forKey: eeaKey) != nil {
            body["eea"] = defaults.bool(forKey: eeaKey)
        }
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
        guard config != nil else { return }
        let installUid = resolveInstallUid()
        var body: [String: Any] = [
            "user_id": installUid,
            "install_uid": installUid,
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
        guard !isRuntimeCircuitOpen() else { return }
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
                applyLocalInstallConversionRule()
            }
        }
    }

    // Registration starts at Apple's default value 0. If the active schema
    // assigns install/first_open a different value, apply that configured value
    // as soon as cached or freshly fetched schema data is available.
    private static func applyLocalInstallConversionRule() {
        guard config?.integrationTestToken == nil else { return }
        guard let schema, let window = currentInstallConversionWindow() else { return }
        let updates = ["install", "first_open"].compactMap { event -> ConversionUpdate? in
            guard let encoded = ConversionEncoder.encode(schema: schema, event: event) else { return nil }
            // A lock finalizes only the window in which its event occurred.
            // Install/first_open happened in window 0 and must not lock 1–2.
            return window == 0 || !encoded.lockWindow
                ? encoded
                : ConversionUpdate(fine: encoded.fine, coarse: encoded.coarse, lockWindow: false)
        }
        let remembered = rememberedInstallConversionUpdate(window: window)
        let update = updates.reduce(remembered) { current, incoming in
            mergeMonotonicConversionUpdates(current: current, incoming: incoming)
        }
        guard let update else { return }
        rememberInstallConversionUpdate(update, window: window)
        SKANUpdater.apply(
            update,
            adAttributionTarget: .install,
            conversionTag: nil
        )
    }

    // A late billing event can produce a server-calculated CV without
    // inventing an analytics session. Foreground/session and track responses
    // also carry the same update.
    private static func syncServerConversionValue() {
        guard let config,
              config.integrationTestToken == nil,
              config.sdkSecret?.isEmpty == false else { return }
        let installUid = resolveInstallUid()
        let body: [String: Any] = [
            "user_id": installUid,
            "install_uid": installUid,
            "first_open_at": iso8601.string(from: resolveFirstOpenAt()),
            "sdk_source": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
        ]
        send(
            path: "sdk/conversion-value",
            body: body,
            dedupeKey: "conversion-value-sync"
        )
    }

    @_spi(Testing) public static func decodeServerConversionInstruction(
        _ data: Data?
    ) -> ServerConversionInstruction? {
        guard let data,
              let envelope = try? JSONDecoder().decode(ServerConversionEnvelope.self, from: data),
              envelope.conversionUpdate?.update != nil else { return nil }
        return envelope.conversionUpdate
    }

    private static func applyServerConversionResponse(_ data: Data?) {
        guard let instruction = decodeServerConversionInstruction(data),
              let update = instruction.update else { return }
        guard currentInstallConversionWindow() == instruction.window else {
            return log("server conversion response belongs to a different Apple window — skipped")
        }
        let safeUpdate = monotonicInstallConversionUpdate(update, window: instruction.window)
        log(
            "server schema v\(instruction.schemaVersion) → fine \(safeUpdate.fine), "
            + "coarse \(safeUpdate.coarse ?? "—"), lock \(safeUpdate.lockWindow)"
        )
        SKANUpdater.apply(
            safeUpdate,
            adAttributionTarget: .install,
            conversionTag: nil
        )
    }

    @_spi(Testing) public static func mergeMonotonicConversionUpdates(
        current: ConversionUpdate?,
        incoming: ConversionUpdate
    ) -> ConversionUpdate {
        guard let current else { return incoming }
        let coarseOrder = ["low": 1, "medium": 2, "high": 3]
        let currentRank = current.coarse.flatMap { coarseOrder[$0] } ?? 0
        let incomingRank = incoming.coarse.flatMap { coarseOrder[$0] } ?? 0
        return ConversionUpdate(
            fine: max(current.fine, incoming.fine),
            coarse: incomingRank > currentRank ? incoming.coarse : current.coarse,
            lockWindow: current.lockWindow || incoming.lockWindow
        )
    }

    @_spi(Testing) public static func installConversionWindow(
        firstOpenAt: Date,
        now: Date
    ) -> Int? {
        let age = now.timeIntervalSince(firstOpenAt)
        guard age >= 0 else { return nil }
        let day: TimeInterval = 24 * 60 * 60
        if age < 2 * day { return 0 }
        if age < 7 * day { return 1 }
        if age <= 35 * day { return 2 }
        return nil
    }

    private static func currentInstallConversionWindow() -> Int? {
        installConversionWindow(firstOpenAt: resolveFirstOpenAt(), now: Date())
    }

    private static func highestInstallCoarseKey(window: Int) -> String {
        highestInstallCoarseKeyPrefix + String(window)
    }

    private static func installWindowLockedKey(window: Int) -> String {
        installWindowLockedKeyPrefix + String(window)
    }

    private static func rememberedInstallConversionUpdate(window: Int) -> ConversionUpdate? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: highestInstallFineKey) != nil else { return nil }
        return ConversionUpdate(
            fine: defaults.integer(forKey: highestInstallFineKey),
            coarse: defaults.string(forKey: highestInstallCoarseKey(window: window)),
            lockWindow: defaults.bool(forKey: installWindowLockedKey(window: window))
        )
    }

    private static func rememberInstallConversionUpdate(_ update: ConversionUpdate, window: Int) {
        let defaults = UserDefaults.standard
        defaults.set(update.fine, forKey: highestInstallFineKey)
        let coarseKey = highestInstallCoarseKey(window: window)
        if let coarse = update.coarse {
            defaults.set(coarse, forKey: coarseKey)
        } else {
            defaults.removeObject(forKey: coarseKey)
        }
        defaults.set(update.lockWindow, forKey: installWindowLockedKey(window: window))
    }

    private static func monotonicInstallConversionUpdate(
        _ incoming: ConversionUpdate,
        window: Int
    ) -> ConversionUpdate {
        let merged = mergeMonotonicConversionUpdates(
            current: rememberedInstallConversionUpdate(window: window),
            incoming: incoming
        )
        rememberInstallConversionUpdate(merged, window: window)
        return merged
    }

    private static func loadCachedSchema() -> ConversionSchema? {
        guard let data = UserDefaults.standard.data(forKey: schemaCacheKey) else { return nil }
        return try? JSONDecoder().decode(ConversionSchema.self, from: data)
    }

    // MARK: - Attribution

    private struct AttributionEnvelope: Decodable {
        let ok: Bool
        let attribution: AttributionSnapshot?
    }

    private struct AttributionSnapshot: Decodable {
        let revision: String
        let provider: String
        let data: [String: String]
    }

    private static func attribution(from snapshot: AttributionSnapshot) -> TrackHubAttribution {
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

    // On `queue`. Only production calls are eligible.
    private static func fetchAttributionIfNeeded(
        completion: ((TrackHubAttribution?) -> Void)? = nil
    ) {
        if let completion { attributionCompletions.append(completion) }
        guard !isRuntimeCircuitOpen() else {
            finishAttributionCompletions(nil)
            return
        }
        guard !trackingDisabled else {
            finishAttributionCompletions(nil)
            return
        }
        guard !attConsentDelayActive else { return }
        guard !attributionFetchInFlight else { return }
        guard let config, config.integrationTestToken == nil else {
            finishAttributionCompletions(nil)
            return
        }
        let installUid = resolveInstallUid()
        let installToken = InstallCredentialStore.load(
            ingestToken: config.ingestToken,
            installUid: installUid
        )
        if installToken == nil {
            finishAttributionCompletions(nil)
            reportInstallIfNeeded()
            return log("attribution waiting for install credential")
        }
        attributionFetchInFlight = true
        attributionFetchGeneration &+= 1
        let generation = attributionFetchGeneration
        queue.asyncAfter(deadline: .now() + callbackTimeout) {
            guard attributionFetchInFlight,
                  attributionFetchGeneration == generation else { return }
            attributionFetchInFlight = false
            finishAttributionCompletions(nil)
            log("attribution fetch timed out — will retry")
        }
        let consume: (Data?) -> Void = { responseData in
            queue.async {
                guard attributionFetchInFlight,
                      attributionFetchGeneration == generation else { return }
                attributionFetchInFlight = false
                guard let responseData,
                      let envelope = try? JSONDecoder().decode(AttributionEnvelope.self, from: responseData),
                      envelope.ok else {
                    finishAttributionCompletions(nil)
                    log("attribution fetch failed — will retry")
                    return
                }
                guard let snapshot = envelope.attribution else {
                    finishAttributionCompletions(nil)
                    return
                }
                guard snapshot.provider == "custom" else {
                    finishAttributionCompletions(nil)
                    log("server returned an invalid attribution provider")
                    return
                }
                let resolved = attribution(from: snapshot)
                let changed = currentAttributionSnapshot?.revision != resolved.revision
                currentAttributionSnapshot = resolved
                finishAttributionCompletions(resolved)
                if changed, let handler = config.attributionChangedHandler {
                    DispatchQueue.main.async { handler(resolved) }
                }
            }
        }
        guard let installToken, let networkConfig = currentNetworkConfig(),
              let bodyData = try? JSONSerialization.data(withJSONObject: ["install_uid": installUid]) else {
            attributionFetchInFlight = false
            finishAttributionCompletions(nil)
            return
        }
        postRaw(
            config: networkConfig,
            path: "sdk/attribution",
            bodyData: bodyData,
            installToken: installToken
        ) { status, responseData in
            consume(status.map(isSuccess) == true ? responseData : nil)
        }
    }

    private struct PendingPrivacyErasure: Codable {
        let installUid: String
        let reason: String
        var attempts: Int
        var nextAttemptAt: TimeInterval
        var launchOnly: Bool?
    }

    private static func isPrivacyStopRequested() -> Bool {
        privacyStateLock.lock()
        defer { privacyStateLock.unlock() }
        return privacyStopRequested
    }

    private static func privacyDirectoryURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("TrackHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pendingErasureFileURL() -> URL {
        privacyDirectoryURL().appendingPathComponent("trackhub_privacy_v2.json")
    }

    private static func hasPendingErasureState() -> Bool {
        FileManager.default.fileExists(atPath: pendingErasureFileURL().path)
            || UserDefaults.standard.object(forKey: privacyPendingKey) != nil
    }

    /// Migrate every token-scoped 2.0 prerelease state, not just the current
    /// token. This is what keeps a pending erasure fail-closed across sdkKey
    /// rotation.
    private static func migrateLegacyPrivacyState() {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys
        if keys.contains(where: {
            $0.hasPrefix(legacyPrivacyDisabledKeyPrefix)
                && $0 != privacyDisabledKey
                && defaults.bool(forKey: $0)
        }) {
            defaults.set(true, forKey: privacyDisabledKey)
        }
        guard loadPendingErasure() == nil else { return }

        var candidates: [(Data, URL?, String?)] = []
        let directory = privacyDirectoryURL()
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.lastPathComponent.hasPrefix("trackhub_privacy_")
                && file.lastPathComponent != "trackhub_privacy_v2.json" {
                if let data = try? Data(contentsOf: file), data.count <= 1_024 {
                    candidates.append((data, file, nil))
                }
            }
        }
        for key in keys where key.hasPrefix(legacyPrivacyPendingKeyPrefix) && key != privacyPendingKey {
            if let data = defaults.data(forKey: key), data.count <= 1_024 {
                candidates.append((data, nil, key))
            }
        }
        for (data, file, key) in candidates {
            guard let pending = try? JSONDecoder().decode(PendingPrivacyErasure.self, from: data),
                  persistPendingErasure(pending) else { continue }
            if let file { try? FileManager.default.removeItem(at: file) }
            if let key { defaults.removeObject(forKey: key) }
            defaults.set(true, forKey: privacyDisabledKey)
            break
        }
    }

    @discardableResult
    private static func persistPendingErasure(installUid: String, reason: String) -> Bool {
        let pending = PendingPrivacyErasure(
            installUid: installUid,
            reason: reason,
            attempts: 0,
            nextAttemptAt: 0,
            launchOnly: false
        )
        return persistPendingErasure(pending)
    }

    @discardableResult
    private static func persistPendingErasure(_ pending: PendingPrivacyErasure) -> Bool {
        guard let data = try? JSONEncoder().encode(pending), data.count <= 1_024 else { return false }
        do {
            try data.write(to: pendingErasureFileURL(), options: .atomic)
            UserDefaults.standard.removeObject(forKey: privacyPendingKey)
            return true
        } catch {
            // Application Support can be temporarily unavailable before first
            // unlock. Keep a second durable copy so a killed process still
            // resumes erasure; the next successful file write removes it.
            UserDefaults.standard.set(data, forKey: privacyPendingKey)
            let stored = UserDefaults.standard.synchronize()
            if !stored { log("privacy erasure task could not be persisted") }
            return stored
        }
    }

    private static func loadPendingErasure() -> PendingPrivacyErasure? {
        let file = pendingErasureFileURL()
        if let data = try? Data(contentsOf: file), data.count <= 1_024,
           let pending = try? JSONDecoder().decode(PendingPrivacyErasure.self, from: data) {
            return pending
        }
        guard let legacy = UserDefaults.standard.data(forKey: privacyPendingKey),
              let pending = try? JSONDecoder().decode(PendingPrivacyErasure.self, from: legacy)
        else { return nil }
        _ = persistPendingErasure(pending)
        return pending
    }

    private static func stopAndClearLocalMeasurement(retainingInstallUid: String?) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryDeadline = nil
        transientRetryNotBefore = nil
        odmInfoDelayWorkItem?.cancel()
        odmInfoDelayWorkItem = nil
        odmDeliveryState.cancel()
        deliveryCompletions.removeAll()
        currentAttributionSnapshot = nil
        attributionFetchInFlight = false
        sessionTracker = nil
        if eventQueue?.removeAll() == false {
            log("privacy erasure could not clear the offline queue")
        }
        purgeAllOfflineQueueFiles()
        for key in [
            pushTokenKey, pushEnvironmentKey, deviceIdKey,
            gclidKey, gbraidKey, wbraidKey,
            pendingGclidKey, pendingGbraidKey, pendingWbraidKey,
            openAiOpprefKey, pendingOpenAiOpprefKey, appInstanceIdKey, odmInfoKey,
            adUserDataKey, adPersonalizationKey, eeaKey,
            piplConsentKey, crossBorderTransferConsentKey, adsMeasurementConsentKey,
            countryCodeKey, adAttributionConversionTagKey,
            externalIdentitiesKey, externalIdentityAckKey,
            installSentKey, firstOpenAtKey, schemaCacheKey,
            highestInstallFineKey, "trackhub.session_seq", "trackhub.session_last_activity",
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if !FirstOpenStore.remove(legacyKey: firstOpenAtKey) {
            log("first-open timestamp file could not be removed")
        }
        purgeRetiredMeasurementGeographyState()
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter {
                $0.hasPrefix(highestInstallCoarseKeyPrefix)
                    || $0.hasPrefix(installWindowLockedKeyPrefix)
                    || $0.hasPrefix(installCredentialBootstrapKeyPrefix)
            }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        if let retainingInstallUid {
            if !InstallIdentityStore.retain(retainingInstallUid, legacyKey: installUidKey) {
                log("install identity could not be retained for privacy erasure")
            }
        } else {
            if !InstallIdentityStore.remove(legacyKey: installUidKey) {
                log("install identity file could not be removed")
            }
        }
    }

    private static func purgeAllOfflineQueueFiles() {
        let directory = privacyDirectoryURL()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            let name = file.lastPathComponent
            if name == "trackhub_queue.json"
                || name.hasPrefix("trackhub_queue_")
                || name.contains(".json.corrupt-") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func addPrivacyErasureCompletion(_ completion: ((Bool) -> Void)?) {
        guard let completion else { return }
        if let previous = privacyErasureCompletion {
            privacyErasureCompletion = { success in
                previous(success)
                completion(success)
            }
        } else {
            privacyErasureCompletion = completion
        }
    }

    private static func completePendingErasure(completion: ((Bool) -> Void)?) {
        UserDefaults.standard.set(true, forKey: privacyDisabledKey)
        UserDefaults.standard.synchronize()
        InstallCredentialStore.deleteAll()
        // The credential and install id are erased last: both are required to
        // authorize/recover an offline privacy job.
        if !InstallIdentityStore.remove(legacyKey: installUidKey) {
            log("install identity file could not be removed after privacy erasure")
        }
        try? FileManager.default.removeItem(at: pendingErasureFileURL())
        UserDefaults.standard.removeObject(forKey: privacyPendingKey)
        privacyErasureInFlight = false
        privacyRetryWorkItem?.cancel()
        privacyRetryWorkItem = nil
        addPrivacyErasureCompletion(completion)
        let callback = privacyErasureCompletion
        privacyErasureCompletion = nil
        DispatchQueue.main.async { callback?(true) }
    }

    private static func schedulePendingErasureRetry(
        _ pending: PendingPrivacyErasure,
        completion: ((Bool) -> Void)?,
        launchOnly: Bool = false
    ) {
        var updated = pending
        updated.attempts = min(pending.attempts + 1, 30)
        updated.launchOnly = launchOnly
        let delay = launchOnly
            ? 24 * 60 * 60
            : retryDelay(attempt: updated.attempts, jitter: Double.random(in: 0...1))
        updated.nextAttemptAt = Date().timeIntervalSince1970 + delay
        _ = persistPendingErasure(updated)
        privacyErasureInFlight = false
        privacyRetryWorkItem?.cancel()
        guard !launchOnly else {
            privacyRetryWorkItem = nil
            log("privacy erasure rejected — retry deferred until a later launch/foreground")
            return
        }
        let item = DispatchWorkItem { retryPendingErasure() }
        privacyRetryWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private static func retryPendingErasure(completion: ((Bool) -> Void)? = nil) {
        addPrivacyErasureCompletion(completion)
        guard !privacyErasureInFlight,
              let config,
              let networkConfig = currentNetworkConfig(purpose: .measurement),
              let pending = loadPendingErasure() else {
            if loadPendingErasure() == nil {
                let callback = privacyErasureCompletion
                privacyErasureCompletion = nil
                DispatchQueue.main.async { callback?(false) }
            }
            return
        }
        let now = Date().timeIntervalSince1970
        guard pending.nextAttemptAt <= now else {
            if pending.launchOnly == true { return }
            privacyRetryWorkItem?.cancel()
            let item = DispatchWorkItem { retryPendingErasure() }
            privacyRetryWorkItem = item
            queue.asyncAfter(deadline: .now() + pending.nextAttemptAt - now, execute: item)
            return
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: [
            "install_uid": pending.installUid,
            "reason": pending.reason,
        ]) else {
            schedulePendingErasureRetry(pending, completion: completion, launchOnly: true)
            return
        }
        privacyErasureInFlight = true

        func recover(_ clockRetried: Bool) {
            postRaw(
                config: networkConfig,
                path: "sdk/forget-device/recover",
                bodyData: bodyData
            ) { status, responseData in
                queue.async {
                    if status.map(isSuccess) == true || status == 410 {
                        completePendingErasure(completion: completion)
                    } else if status == 401, !clockRetried, applyServerClock(responseData) {
                        recover(true)
                    } else {
                        schedulePendingErasureRetry(
                            pending,
                            completion: completion,
                            launchOnly: !isRetryable(status)
                        )
                    }
                }
            }
        }

        guard let installToken = InstallCredentialStore.load(
            ingestToken: config.ingestToken,
            installUid: pending.installUid
        ) else {
            recover(false)
            return
        }
        postRaw(
            config: networkConfig,
            path: "sdk/forget-device",
            bodyData: bodyData,
            installToken: installToken
        ) { status, responseData in
            queue.async {
                if status.map(isSuccess) == true || status == 410 {
                    completePendingErasure(completion: completion)
                } else if status == 401 {
                    if applyServerClock(responseData) {
                        recover(true)
                    } else {
                        recover(false)
                    }
                } else {
                    schedulePendingErasureRetry(
                        pending,
                        completion: completion,
                        launchOnly: !isRetryable(status)
                    )
                }
            }
        }
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

    @_spi(Testing) public static func offlineQueueNamespace(
        for testToken: String?,
        ingestToken: String? = nil
    ) -> String {
        let environment: String
        if let token = testToken, !token.isEmpty {
            let digest = SHA256.hash(data: Data(token.utf8))
            environment = "test-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        } else {
            environment = "production"
        }
        guard let ingestToken, !ingestToken.isEmpty else { return environment }
        let appDigest = SHA256.hash(data: Data(ingestToken.utf8))
        let app = appDigest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(environment)-app-\(app)"
    }

    private static func queueFileURL(testToken: String?, ingestToken: String) -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let dir = base.appendingPathComponent("TrackHub", isDirectory: true)
        try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(resourceValues)
        let namespace = offlineQueueNamespace(for: testToken, ingestToken: ingestToken)
        let filename = "trackhub_queue_\(namespace).json"
        let destination = dir.appendingPathComponent(filename)
        // One-time migration from the environment-only 2.0 queue and the older
        // Caches location. The current key is the only safe app association we
        // can infer for those legacy files.
        if !manager.fileExists(atPath: destination.path) {
            let legacyNamespace = offlineQueueNamespace(for: testToken)
            let legacyFilename = legacyNamespace == "production"
                ? "trackhub_queue.json"
                : "trackhub_queue_\(legacyNamespace).json"
            let legacyApplicationSupport = dir.appendingPathComponent(legacyFilename)
            if manager.fileExists(atPath: legacyApplicationSupport.path) {
                try? manager.moveItem(at: legacyApplicationSupport, to: destination)
            } else if let oldCaches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let legacyCaches = oldCaches.appendingPathComponent(legacyFilename)
                if manager.fileExists(atPath: legacyCaches.path) {
                    try? manager.moveItem(at: legacyCaches, to: destination)
                }
            }
        }
        return destination
    }

    // Persist first, then let one bounded delivery task drain the queue. A slow
    // or unavailable TrackHub endpoint never occupies this state queue and
    // never creates one URLSession task per buffered event.
    @discardableResult
    private static func send(
        path: String,
        body: [String: Any],
        kind: String? = nil,
        dedupeKey: String? = nil,
        completion: ((Int?) -> Void)? = nil
    ) -> Bool {
        guard !trackingDisabled,
              !isPrivacyStopRequested(),
              !isRuntimeCircuitOpen() else { return false }
        var payload = body
        if let testToken = config?.integrationTestToken { payload["test_run_token"] = testToken }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            log("\(path) payload is not JSON-serializable — skipped")
            completion?(nil)
            return false
        }
        guard data.count <= maxReportBytes else {
            log("\(path) payload exceeds \(maxReportBytes) bytes — skipped")
            completion?(nil)
            return false
        }
        guard let targetQueue = eventQueue else {
            completion?(nil)
            return false
        }
        let report = PendingReport(
            path: path,
            body: data,
            kind: kind,
            dedupeKey: dedupeKey,
            firstOpenEnrichment: firstOpenEnrichmentEligibility(path: path, body: payload)
        )
        guard let reportID = targetQueue.enqueue(report) else {
            if targetQueue.storageFailure {
                openRuntimeCircuit(.storage, detail: "offline queue persistence failed")
            }
            log("\(path) could not be written to the offline queue — skipped")
            completion?(nil)
            return false
        }
        let liveReportIDs = Set(targetQueue.items.map(\.id))
        deliveryCompletions = deliveryCompletions.filter { liveReportIDs.contains($0.key) }
        if let completion { deliveryCompletions[reportID] = completion }
        if firstOpenDeliveryDelayActive {
            log("\(path) buffered during first-open enrichment wait")
            return true
        }
        flush()
        return true
    }

    // Drain exactly one report at a time; each is signed FRESH at send time so
    // a stale timestamp never rejects buffered traffic.
    private static func flush() {
        guard !trackingDisabled, !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return }
        guard !firstOpenDeliveryDelayActive else { return }
        guard !deliveryInFlight else { return }
        guard let targetQueue = eventQueue else { return }
        guard targetQueue.prepareForDelivery() else {
            // Complete-until-first-authentication storage may be unavailable
            // briefly after boot. Do not overwrite or skip the disk backlog.
            scheduleRetry(at: Date().addingTimeInterval(30))
            return
        }
        guard let report = targetQueue.nextForDelivery else { return }

        let isFifoHead = targetQueue.items.first?.id == report.id
        let transientNotBefore = isFifoHead
            ? (transientRetryNotBefore ?? .distantPast)
            : .distantPast
        let notBefore = max(report.nextAttemptAt, transientNotBefore)
        if notBefore > Date() {
            scheduleRetry(at: notBefore)
            return
        }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryDeadline = nil
        transientRetryNotBefore = nil
        guard let networkConfig = currentNetworkConfig() else { return }

        guard let prepared = targetQueue.prepareNextForDispatch(capacityFallback: { pending in
            pending.firstOpenEnrichment?.bodyForFirstDispatch(
                report: pending, currentInstallUid: resolveInstallUid(), signals: [:],
                measurementAllowed: false, now: Date()
            )
        }, enrich: { pending in
            guard let eligibility = pending.firstOpenEnrichment else { return nil }
            var signals: [String: Any] = [:]
            appendOdmInfo(to: &signals)
            appendAppConversionDeviceIdentifier(to: &signals)
            return eligibility.bodyForFirstDispatch(
                report: pending, currentInstallUid: resolveInstallUid(), signals: signals,
                measurementAllowed: firstOpenSignalEnrichmentAllowed(), now: Date()
            )
        }) else {
            if targetQueue.storageFailure {
                openRuntimeCircuit(.storage, detail: "cannot persist first-dispatch payload")
            } else {
                scheduleRetry(at: Date().addingTimeInterval(30))
            }
            return
        }
        guard !isPrivacyStopRequested() else { return }

        deliveryInFlight = true
        postRaw(
            config: networkConfig,
            path: prepared.path,
            bodyData: prepared.body
        ) { status, responseData in
            queue.async {
                deliveryInFlight = false
                handleDeliveryResult(
                    targetQueue: targetQueue,
                    report: prepared,
                    status: status,
                    responseData: responseData
                )
                flush()
            }
        }
    }

    private static func handleDeliveryResult(
        targetQueue: EventQueue,
        report: PendingReport,
        status: Int?,
        responseData: Data?
    ) {
        guard !isRuntimeCircuitOpen() else { return }
        guard targetQueue.items.contains(where: { $0.id == report.id }) else {
            deliveryCompletions.removeValue(forKey: report.id)
            return
        }
        if status == 410, isServerPrivacyStop(responseData) {
            let completion = deliveryCompletions.removeValue(forKey: report.id)
            privacyStateLock.lock()
            privacyStopRequested = true
            privacyStateLock.unlock()
            trackingDisabled = true
            UserDefaults.standard.set(true, forKey: privacyDisabledKey)
            _ = UserDefaults.standard.synchronize()
            stopAndClearLocalMeasurement(retainingInstallUid: nil)
            InstallCredentialStore.deleteAll()
            log("server privacy erasure confirmed — tracking permanently disabled")
            completion?(status)
            return
        }
        let correctedClock = status == 401 && applyServerClock(responseData)
        if correctedClock || isRetryable(status) {
            let attempts = report.attempts + 1
            let delay = correctedClock && attempts <= 3
                ? 1
                : retryDelay(attempt: attempts, jitter: Double.random(in: 0...1))
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
                if targetQueue.storageFailure {
                    openRuntimeCircuit(.storage, detail: "offline retry state persistence failed")
                }
            }
            log(correctedClock
                ? "device clock corrected — retrying \(report.path)"
                : "\(report.path) delivery failed — retrying with backoff")
            return
        }

        if status == 401, !credentialsFailureSignaled {
            credentialsFailureSignaled = true
            if let handler = config?.deliveryFailureHandler {
                let failure = TrackHubDeliveryFailure.credentialsRejected(path: report.path)
                DispatchQueue.main.async { handler(failure) }
            }
            log("SDK credentials rejected after clock recovery — host notified")
            openRuntimeCircuit(.credentials, detail: "SDK credentials rejected")
        }

        if !targetQueue.remove(id: report.id) {
            log("\(report.path) queue removal could not be persisted")
            if targetQueue.storageFailure {
                openRuntimeCircuit(.storage, detail: "offline delivery state persistence failed")
            }
        }
        let completion = deliveryCompletions.removeValue(forKey: report.id)
        if isSuccess(status) {
            if report.path == "sdk/session"
                || report.path == "sdk/track"
                || report.path == "sdk/conversion-value" {
                applyServerConversionResponse(responseData)
            }
            switch report.kind {
            case "production_install":
                UserDefaults.standard.set(true, forKey: installSentKey)
                saveInstallCredential(from: responseData)
                log("install reported")
                syncPersistedExternalIdentities()
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

    @_spi(Testing) public static func isServerPrivacyStop(_ responseData: Data?) -> Bool {
        guard let responseData,
              let value = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let error = value["error"] as? String
        else { return false }
        return error == "device_erased" || error == "privacy_erased"
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
        return cap * unit
    }

    private static func resolveDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let id = "dev_" + UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    private static func resolveInstallUid() -> String {
        let resolution = InstallIdentityStore.resolve(legacyKey: installUidKey)
        if !resolution.isDurable {
            openRuntimeCircuit(.storage, detail: "install identity persistence failed")
            log("install identity is not durable — measurement disabled for this process")
        }
        return resolution.value
    }

    // Google's App Conversion API requires `fot` on every post-install event.
    // Persist the SDK's first observed launch before any asynchronous network
    // request starts, so session/purchase reports remain valid even if they
    // reach the server before the install report.
    private static func resolveFirstOpenAt() -> Date {
        let resolution = FirstOpenStore.resolve(legacyKey: firstOpenAtKey)
        if !resolution.isDurable {
            openRuntimeCircuit(.storage, detail: "first-open timestamp persistence failed")
            log("first-open timestamp is not durable — measurement disabled for this process")
        }
        return resolution.value
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

    internal static func purgeRetiredMeasurementGeographyState() {
        for key in retiredMeasurementGeoKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func appendAppConversionUserAgentContext(to body: inout [String: Any]) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        body["os_version"] = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
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

    private static func firstOpenSignalEnrichmentAllowed() -> Bool {
        guard !trackingDisabled, !isPrivacyStopRequested(), !isRuntimeCircuitOpen() else { return false }
        let defaults = UserDefaults.standard
        return [adUserDataKey, piplConsentKey, crossBorderTransferConsentKey, adsMeasurementConsentKey]
            .allSatisfy { defaults.object(forKey: $0) == nil || defaults.bool(forKey: $0) }
    }

    private static func firstOpenEnrichmentEligibility(path: String, body: [String: Any]) -> FirstOpenReportEnrichment? {
        guard firstOpenDeliveryDelayActive, FirstOpenReportEnrichment.paths.contains(path),
              firstOpenSignalEnrichmentAllowed(),
              let installUid = body["install_uid"] as? String,
              installUid == resolveInstallUid() else { return nil }
        let expiresAt = resolveFirstOpenAt().addingTimeInterval(FirstOpenReportEnrichment.maximumAge)
        guard Date() <= expiresAt else { return nil }
        var allowAdvertisingId = false
        #if os(iOS) && canImport(AppTrackingTransparency)
        let att = ATTrackingManager.trackingAuthorizationStatus
        allowAdvertisingId = att == .notDetermined || att == .authorized
        #endif
        return FirstOpenReportEnrichment(installUid: installUid, expiresAt: expiresAt,
                                        allowAdvertisingId: allowAdvertisingId)
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
        } else if let idfv = identifierForVendorSnapshot {
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

    private static func normalizedExternalProvider(_ raw: String) -> String? {
        let provider = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if provider == "apphud" || provider == "revenuecat" { return provider }
        guard provider.hasPrefix("custom:") else { return nil }
        let slug = provider.dropFirst("custom:".count)
        guard !slug.isEmpty, slug.count <= 63,
              slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              slug.first?.isLetter == true || slug.first?.isNumber == true else { return nil }
        return provider
    }

    @_spi(Testing) public static func normalizedExternalProviderForTesting(
        _ raw: String
    ) -> String? {
        normalizedExternalProvider(raw)
    }

    private static func externalIdentityFingerprint(provider: String, userId: String?) -> String {
        SHA256.hash(data: Data("\(provider)\u{0}\(userId ?? "<logout>")".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func syncPersistedExternalIdentities() {
        let desired = UserDefaults.standard.dictionary(forKey: externalIdentitiesKey)
            as? [String: String] ?? [:]
        for (provider, stored) in desired {
            syncExternalIdentity(provider: provider, userId: stored.isEmpty ? nil : stored)
        }
    }

    // The desired identity is persisted before enqueue and the server ACK is
    // persisted separately. A full queue or process death therefore retries
    // the latest provider-scoped state on the next launch.
    private static func syncExternalIdentity(provider: String, userId: String?) {
        guard config != nil, normalizedExternalProvider(provider) == provider else { return }
        let installAcknowledged = UserDefaults.standard.bool(forKey: installSentKey)
        let isIntegrationTest = config?.integrationTestToken != nil
        guard shouldEnqueueExternalIdentity(
            installAcknowledged: installAcknowledged,
            integrationTest: isIntegrationTest
        ) else {
            log("external identity waiting for install acknowledgement")
            return
        }
        let fingerprint = externalIdentityFingerprint(provider: provider, userId: userId)
        let acknowledged = UserDefaults.standard.dictionary(forKey: externalIdentityAckKey)
            as? [String: String] ?? [:]
        guard acknowledged[provider] != fingerprint else { return }
        let body: [String: Any] = [
            "provider": provider,
            "external_user_id": userId ?? NSNull(),
            "install_uid": resolveInstallUid(),
            "sdk_source": "trackhub-ios",
            "sdk_version": Self.sdkVersion,
        ]
        _ = send(
            path: "sdk/identity",
            body: body,
            kind: "external_identity",
            dedupeKey: "external_identity:\(provider)"
        ) { status in
            guard status.map(isSuccess) == true else { return }
            var updated = UserDefaults.standard.dictionary(forKey: externalIdentityAckKey)
                as? [String: String] ?? [:]
            updated[provider] = fingerprint
            UserDefaults.standard.set(updated, forKey: externalIdentityAckKey)
            reportPushTokenIfAvailable()
            syncServerConversionValue()
        }
    }

    @_spi(Testing) public static func shouldEnqueueExternalIdentity(
        installAcknowledged: Bool,
        integrationTest: Bool
    ) -> Bool {
        integrationTest || installAcknowledged
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

    @_spi(Testing) public static func serverClockOffset(
        responseData data: Data?,
        localTimeMilliseconds: Int64
    ) -> Int64? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] as? String == "clock_skew",
              let number = object["server_time_ms"] as? NSNumber else { return nil }
        let serverTime = number.int64Value
        guard (1_577_836_800_000...4_102_444_800_000).contains(serverTime) else { return nil }
        return serverTime - localTimeMilliseconds
    }

    private static func applyServerClock(_ data: Data?) -> Bool {
        let localTime = Int64(Date().timeIntervalSince1970 * 1_000)
        guard let offset = serverClockOffset(
            responseData: data,
            localTimeMilliseconds: localTime
        ) else { return false }
        clockOffsetMilliseconds = offset
        return true
    }

    private static func currentNetworkConfig(
        purpose: NetworkPurpose = .trackingEligible
    ) -> NetworkConfig? {
        guard let config else { return nil }
        let endpoint: URL
        if purpose == .trackingEligible,
           isTrackingAuthorized(),
           let trackingEndpoint = config.trackingEndpoint {
            endpoint = trackingEndpoint
        } else {
            endpoint = config.endpoint
        }
        return NetworkConfig(
            endpoint: endpoint,
            ingestToken: config.ingestToken,
            sdkSecret: config.sdkSecret
        )
    }

    private static func isTrackingAuthorized() -> Bool {
        #if os(iOS) && canImport(AppTrackingTransparency)
        return ATTrackingManager.trackingAuthorizationStatus == .authorized
        #else
        return false
        #endif
    }

    private static func postRaw(
        config: NetworkConfig,
        path: String,
        bodyData: Data,
        installToken: String? = nil,
        completion: @escaping (Int?, Data?) -> Void
    ) {
        let url = config.endpoint.appendingPathComponent("ingest").appendingPathComponent(config.ingestToken).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TrackHub-iOS/\(Self.sdkVersion)", forHTTPHeaderField: "User-Agent")
        if let installToken {
            request.setValue(installToken, forHTTPHeaderField: "X-TrackHub-Install-Token")
        }
        request.httpBody = bodyData
        if let secret = config.sdkSecret, !secret.isEmpty {
            let localTime = Int64(Date().timeIntervalSince1970 * 1_000)
            let ts = String(localTime + clockOffsetMilliseconds)
            let scope = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let message = "\(ts).\(config.ingestToken).\(scope).\(String(data: bodyData, encoding: .utf8) ?? "")"
            let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            request.setValue(ts, forHTTPHeaderField: "X-TrackHub-Timestamp")
            request.setValue("2", forHTTPHeaderField: "X-TrackHub-Signature-Version")
            request.setValue(mac.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-TrackHub-Signature")
        }
        httpClient.data(for: request, completion: completion)
    }

    private static func installCredentialBootstrapKey(token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return installCredentialBootstrapKeyPrefix
            + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    @_spi(Testing) public static func shouldReportInstallForCredential(
        installAlreadySent: Bool,
        hasCredential: Bool,
        lastAttempt: TimeInterval,
        now: TimeInterval,
        interval: TimeInterval = 24 * 60 * 60
    ) -> Bool {
        if !installAlreadySent { return true }
        if hasCredential { return false }
        return lastAttempt <= 0 || now - lastAttempt >= interval
    }

    private static func saveInstallCredential(from responseData: Data?) {
        guard let config, let responseData,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let token = json["install_token"] as? String,
              let installUid = json["install_uid"] as? String,
              installUid == resolveInstallUid(),
              InstallCredentialStore.save(
                token,
                ingestToken: config.ingestToken,
                installUid: installUid
              ) else { return }
        UserDefaults.standard.removeObject(
            forKey: installCredentialBootstrapKey(token: config.ingestToken)
        )
        log("device-scoped install credential received")
    }

    /// A process-local fail-silent circuit. It is deliberately not persisted:
    /// the next clean app launch retries the SDK from durable state. Privacy
    /// erasure does not consult this flag and remains available even when the
    /// measurement contour has stopped.
    private static func isRuntimeCircuitOpen() -> Bool {
        runtimeCircuitLock.lock()
        let value = runtimeCircuitOpen
        runtimeCircuitLock.unlock()
        return value
    }

    private static func openRuntimeCircuit(_ reason: RuntimeCircuitReason, detail: String) {
        runtimeCircuitLock.lock()
        let firstOpen = !runtimeCircuitOpen
        runtimeCircuitOpen = true
        runtimeCircuitLock.unlock()
        if firstOpen {
            UserDefaults.standard.set([
                "id": UUID().uuidString.lowercased(),
                "reason": reason.rawValue,
                "occurred_at": iso8601.string(from: Date()),
            ], forKey: runtimeCircuitMarkerKey)
            _ = UserDefaults.standard.synchronize()
            log("runtime circuit opened (\(detail)) — measurement disabled until app restart")
        }
    }

    /// Enqueues the previous process's marker only after a valid production
    /// configuration and privacy gate. The UUID is also the durable queue
    /// dedupe key, so a crash around marker removal cannot inflate Health.
    private static func reportRuntimeCircuitDiagnosticIfNeeded() {
        guard config?.integrationTestToken == nil,
              let marker = UserDefaults.standard.dictionary(forKey: runtimeCircuitMarkerKey) else { return }
        guard let id = marker["id"] as? String,
              UUID(uuidString: id) != nil,
              let reason = marker["reason"] as? String,
              RuntimeCircuitReason(rawValue: reason) != nil,
              let occurredAt = marker["occurred_at"] as? String,
              ISO8601DateFormatter().date(from: occurredAt) != nil else {
            UserDefaults.standard.removeObject(forKey: runtimeCircuitMarkerKey)
            return
        }
        let accepted = send(
            path: "sdk/diagnostic",
            body: [
                "id": id,
                "sdk_source": "trackhub-ios",
                "sdk_version": Self.sdkVersion,
                "reason": reason,
                "occurred_at": occurredAt,
            ],
            kind: "sdk_runtime_diagnostic",
            dedupeKey: "sdk_runtime:\(id)"
        )
        if accepted {
            UserDefaults.standard.removeObject(forKey: runtimeCircuitMarkerKey)
        }
    }

    @_spi(Testing) public static func runtimeCircuitOpenForTesting() -> Bool {
        isRuntimeCircuitOpen()
    }

    @_spi(Testing) public static func openRuntimeCircuitForTesting() {
        openRuntimeCircuit(.algorithm, detail: "test")
    }

    @_spi(Testing) public static func runtimeCircuitMarkerReasonForTesting() -> String? {
        UserDefaults.standard.dictionary(forKey: runtimeCircuitMarkerKey)?["reason"] as? String
    }

    @_spi(Testing) public static func resetRuntimeCircuitForTesting() {
        runtimeCircuitLock.lock()
        runtimeCircuitOpen = false
        runtimeCircuitLock.unlock()
        UserDefaults.standard.removeObject(forKey: runtimeCircuitMarkerKey)
    }

    static func log(_ message: String) {
        if debugLogging { print("[TrackHub] \(message)") }
    }
}
