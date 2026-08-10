import Foundation
import CryptoKit
@_spi(Testing) import TrackHub

// Encoder parity tests (mirror of tests/skan.test.ts on the backend).
// Run with: swift run encoder-tests — exits non-zero on any failure.

var failures = 0

func sdkKey(endpoint: String, ingestToken: String, sdkSecret: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [
        "e": endpoint,
        "i": ingestToken,
        "s": sdkSecret,
    ])
    return "thcfg_v1_" + data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("✓ \(name)")
    } else {
        failures += 1
        print("✗ FAILED: \(name)")
    }
}

let schema = ConversionSchema(
    schemaVersion: 3,
    rules: [
        .init(from: 0, to: 0, event: "install"),
        .init(from: 1, to: 9, event: "trial_started", revenueLowCents: 0, revenueHighCents: 0, coarse: "low"),
        .init(from: 10, to: 20, event: "trial_converted", revenueLowCents: 500, revenueHighCents: 1000, coarse: "high"),
    ],
    lockOnEvents: ["trial_converted"]
)

check(
    ConversionEncoder.encode(schema: schema, event: "trial_started")
        == ConversionUpdate(fine: 1, coarse: "low", lockWindow: false),
    "event without revenue encodes to range start with its coarse value"
)

check(ConversionEncoder.encode(schema: schema, event: "trial_converted", revenueCents: 500)?.fine == 10,
      "revenue at range start → fine 10")
check(ConversionEncoder.encode(schema: schema, event: "trial_converted", revenueCents: 1000)?.fine == 20,
      "revenue at range end → fine 20")
check(ConversionEncoder.encode(schema: schema, event: "trial_converted", revenueCents: 750)?.fine == 15,
      "revenue mid-range buckets linearly → fine 15")

check(ConversionEncoder.encode(schema: schema, event: "trial_converted", revenueCents: 1)?.fine == 10,
      "revenue below range clamps to start")
check(ConversionEncoder.encode(schema: schema, event: "trial_converted", revenueCents: 99_999)?.fine == 20,
      "revenue above range clamps to end")

check(ConversionEncoder.encode(schema: schema, event: "trial_converted", revenueCents: 600)?.lockWindow == true,
      "lockWindow fires for configured events")
check(ConversionEncoder.encode(schema: schema, event: "trial_started")?.lockWindow == false,
      "lockWindow stays off for other events")

check(ConversionEncoder.encode(schema: schema, event: "nonexistent") == nil,
      "unknown event returns nil")

let json = """
{
  "schemaVersion": 7,
  "rules": [
    {"from": 1, "to": 9, "event": "trial_started", "revenueLowCents": null,
     "revenueHighCents": null, "coarse": "low"}
  ],
  "coarse": {"high": {"event": "x", "revenueLowCents": 1, "revenueHighCents": 2}},
  "lockOnEvents": ["trial_converted"]
}
""".data(using: .utf8)!
if let decoded = try? JSONDecoder().decode(ConversionSchema.self, from: json) {
    check(decoded.schemaVersion == 7, "decodes schemaVersion from server JSON")
    check(decoded.rules.count == 1 && decoded.rules[0].coarse == "low", "decodes rules with coarse")
    check(decoded.lockOnEvents == ["trial_converted"], "decodes lockOnEvents")
} else {
    check(false, "server JSON decodes")
}

let serverResponse = """
{
  "ok": true,
  "conversion_update": {
    "schema_version": 9,
    "window": 1,
    "fine": 17,
    "coarse": "high",
    "lock_window": true
  }
}
""".data(using: .utf8)!
let serverInstruction = TrackHub.decodeServerConversionInstruction(serverResponse)
check(
    serverInstruction?.schemaVersion == 9
        && serverInstruction?.window == 1
        && serverInstruction?.update == ConversionUpdate(fine: 17, coarse: "high", lockWindow: true),
    "signed SDK response decodes server-managed conversion bits"
)
let invalidServerResponse = """
{"conversion_update":{"schema_version":9,"window":3,"fine":64,"coarse":"high","lock_window":false}}
""".data(using: .utf8)!
check(
    TrackHub.decodeServerConversionInstruction(invalidServerResponse) == nil,
    "server-managed conversion bits fail closed outside Apple's 0...63 range"
)
let monotonic = TrackHub.mergeMonotonicConversionUpdates(
    current: ConversionUpdate(fine: 30, coarse: "low", lockWindow: false),
    incoming: ConversionUpdate(fine: 12, coarse: "high", lockWindow: true)
)
check(
    monotonic == ConversionUpdate(fine: 30, coarse: "high", lockWindow: true),
    "same-window conversion updates retain greatest fine/coarse values and sticky lock"
)
let conversionEpoch = Date(timeIntervalSince1970: 1_700_000_000)
let conversionDay: TimeInterval = 24 * 60 * 60
check(
    TrackHub.installConversionWindow(firstOpenAt: conversionEpoch, now: conversionEpoch.addingTimeInterval(conversionDay)) == 0,
    "days 0–2 use Apple conversion window 0"
)
check(
    TrackHub.installConversionWindow(firstOpenAt: conversionEpoch, now: conversionEpoch.addingTimeInterval(3 * conversionDay)) == 1,
    "days 3–7 use Apple conversion window 1"
)
check(
    TrackHub.installConversionWindow(firstOpenAt: conversionEpoch, now: conversionEpoch.addingTimeInterval(8 * conversionDay)) == 2,
    "days 8–35 use Apple conversion window 2"
)
check(
    TrackHub.installConversionWindow(firstOpenAt: conversionEpoch, now: conversionEpoch.addingTimeInterval(36 * conversionDay)) == nil,
    "server-managed install conversion updates stop after day 35"
)

// SDK Signature HMAC parity with the server (tests/sdk-signature.test.ts):
// HMAC-SHA256("parity" key, v2 endpoint-bound message) must match Node/Android.
let sigMsg = "123.tok.install.{\"a\":1}"
let sigMac = HMAC<SHA256>.authenticationCode(for: Data(sigMsg.utf8), using: SymmetricKey(data: Data("parity".utf8)))
let sigHex = sigMac.map { String(format: "%02x", $0) }.joined()
check(sigHex == "48bd3ea5529853b246d18a578d1ce79aa50c2d3e7f69663b233bd696c5c8a91d",
      "SDK signature HMAC matches the server vector")

let installCredential = "thic_v1_" + String(repeating: "A", count: 43)
check(
    InstallCredentialStore.isValid(installCredential),
    "device-scoped install credential accepts the versioned server shape"
)
check(
    !InstallCredentialStore.isValid("thic_v1_short")
        && !InstallCredentialStore.isValid("thic_v2_" + String(repeating: "A", count: 43)),
    "device-scoped install credential rejects malformed or unknown versions"
)
check(
    InstallCredentialStore.account(ingestToken: "app-a", installUid: "install-1")
        != InstallCredentialStore.account(ingestToken: "app-a", installUid: "install-2"),
    "Keychain account is scoped to one installation without exposing the ingest token"
)
check(
    TrackHub.shouldReportInstallForCredential(
        installAlreadySent: true,
        hasCredential: false,
        lastAttempt: 1_000,
        now: 1_100,
        interval: 200
    ) == false,
    "new SDK against an old server throttles credential bootstrap"
)
check(
    TrackHub.shouldReportInstallForCredential(
        installAlreadySent: true,
        hasCredential: false,
        lastAttempt: 1_000,
        now: 1_201,
        interval: 200
    ),
    "upgraded SDK eventually retries the idempotent install ACK bootstrap"
)
check(
    !TrackHub.shouldReportInstallForCredential(
        installAlreadySent: true,
        hasCredential: true,
        lastAttempt: 0,
        now: 10_000
    ),
    "credential receipt restores the one-install-report steady state"
)

check(TrackHub.normalizedCountryCode(" de ") == "DE",
      "explicit country code is normalized to ISO uppercase")
check(TrackHub.normalizedCountryCode("XX") == nil && TrackHub.normalizedCountryCode("Europe") == nil,
      "unknown and non-ISO country values are rejected")

// ── Session coalescing (30-minute timeout, monotonic sequence) ───────────────
let suiteName = "trackhub.parity.session"
let suite = UserDefaults(suiteName: suiteName)!
suite.removePersistentDomain(forName: suiteName)
var sidN = 0
let tracker = SessionTracker(timeout: 30 * 60, defaults: suite, uuid: { sidN += 1; return "sid\(sidN)" })
let base = Date(timeIntervalSince1970: 1_000_000)
let firstSession = tracker.foreground(at: base)
check(firstSession?.sessionNum == 1 && firstSession?.sessionUid == "sid1",
      "first foreground starts session 1")
tracker.background(at: base.addingTimeInterval(10))
check(tracker.foreground(at: base.addingTimeInterval(1_809)) == nil,
      "foreground at 29:59 coalesces into the same session")
tracker.background(at: base.addingTimeInterval(2_000))
check(tracker.foreground(at: base.addingTimeInterval(3_801))?.sessionNum == 2,
      "foreground at 30:01 starts session 2 (monotonic sequence)")
let forcedSession = tracker.forceForeground(at: base.addingTimeInterval(3_802))
check(forcedSession.sessionNum == 3 && forcedSession.sessionUid == "sid3",
      "a deep-link re-engagement forces a new numbered session immediately")

// ── Offline buffer (FIFO eviction + persistence + removal) ────────────────────
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("thq-\(UUID().uuidString).json")
let q = EventQueue(maxItems: 2, url: tmp)
q.enqueue(PendingReport(id: "a", path: "sdk/session", body: Data("1".utf8)))
q.enqueue(PendingReport(id: "b", path: "sdk/track", body: Data("2".utf8)))
q.enqueue(PendingReport(id: "c", path: "sdk/track", body: Data("3".utf8)))
check(q.items.map { $0.id } == ["b", "c"], "offline buffer evicts the oldest at the cap (FIFO)")
let reloaded = EventQueue(maxItems: 2, url: tmp)
check(reloaded.items.map { $0.id } == ["b", "c"], "offline buffer persists across launches")
reloaded.remove(id: "b")
check(reloaded.items.map { $0.id } == ["c"], "remove(id:) pops a delivered report")
try? FileManager.default.removeItem(at: tmp)

let boundedTmp = FileManager.default.temporaryDirectory.appendingPathComponent("thq-bounded-\(UUID().uuidString).json")
let bounded = EventQueue(maxItems: 2, maxBytes: 2_048, maxItemBytes: 128, url: boundedTmp)
check(
    bounded.enqueue(PendingReport(path: "sdk/track", body: Data(repeating: 1, count: 129))) == nil,
    "offline buffer rejects an oversized individual report"
)
let installID = bounded.enqueue(PendingReport(
    id: "install-a",
    path: "install",
    body: Data("install-1".utf8),
    kind: "production_install",
    dedupeKey: "install"
))
bounded.enqueue(PendingReport(id: "event-a", path: "sdk/track", body: Data("a".utf8)))
bounded.enqueue(PendingReport(id: "event-b", path: "sdk/track", body: Data("b".utf8)))
check(
    bounded.items.map(\.id) == ["install-a", "event-b"],
    "normal traffic cannot evict the queued production install"
)
let replacementID = bounded.enqueue(PendingReport(
    id: "install-b",
    path: "install",
    body: Data("install-2".utf8),
    kind: "production_install",
    dedupeKey: "install"
))
check(
    installID == replacementID && bounded.items.first?.body == Data("install-2".utf8),
    "install retries deduplicate while retaining their durable FIFO id"
)
bounded.enqueue(PendingReport(
    id: "transaction-a",
    path: "sdk/purchase-context",
    body: Data("transaction".utf8),
    kind: "transaction_context",
    dedupeKey: "transaction_context:txn-a"
))
bounded.enqueue(PendingReport(id: "event-c", path: "sdk/track", body: Data("c".utf8)))
check(
    bounded.items.map(\.id) == ["install-a", "transaction-a"],
    "normal traffic cannot evict install or transaction attribution anchors"
)
let retryAt = Date().addingTimeInterval(60)
check(
    bounded.markRetry(id: "install-a", attempts: 3, nextAttemptAt: retryAt),
    "retry metadata is written durably"
)
let boundedReloaded = EventQueue(maxItems: 2, maxBytes: 2_048, maxItemBytes: 128, url: boundedTmp)
check(
    boundedReloaded.items.first?.attempts == 3 &&
        abs((boundedReloaded.items.first?.nextAttemptAt.timeIntervalSince(retryAt)) ?? 99) < 0.001,
    "retry backoff survives an app restart"
)
check(
    ((try? Data(contentsOf: boundedTmp).count) ?? Int.max) <= 2_048,
    "persisted offline queue stays within its byte budget"
)
try? FileManager.default.removeItem(at: boundedTmp)

let corruptTmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("thq-corrupt-\(UUID().uuidString).json")
try? Data("not-json".utf8).write(to: corruptTmp, options: .atomic)
let recoveredFromCorrupt = EventQueue(url: corruptTmp)
let corruptPrefix = corruptTmp.lastPathComponent + ".corrupt-"
let quarantineFiles = (try? FileManager.default.contentsOfDirectory(
    at: corruptTmp.deletingLastPathComponent(),
    includingPropertiesForKeys: nil
)) ?? []
let quarantined = quarantineFiles.filter { $0.lastPathComponent.hasPrefix(corruptPrefix) }
check(
    recoveredFromCorrupt.items.isEmpty &&
        !FileManager.default.fileExists(atPath: corruptTmp.path) &&
        quarantined.count == 1,
    "a corrupt offline queue is quarantined without crashing the host app"
)
for url in quarantined { try? FileManager.default.removeItem(at: url) }

check(
    TrackHub.retryDelay(attempt: 1, jitter: 0) == 0 &&
        TrackHub.retryDelay(attempt: 1, jitter: 1) == 1,
    "first retry uses bounded full-jitter backoff"
)
check(
    TrackHub.retryDelay(attempt: 99, jitter: 1) == 300,
    "retry backoff is capped at five minutes"
)
let clockResponse = try! JSONSerialization.data(withJSONObject: [
    "error": "clock_skew",
    "server_time_ms": 1_800_000_012_345 as Int64,
])
check(
    TrackHub.serverClockOffset(
        responseData: clockResponse,
        localTimeMilliseconds: 1_800_000_000_000
    ) == 12_345,
    "clock-skew response preserves a queued signed event and supplies a safe offset"
)
check(
    TrackHub.serverClockOffset(
        responseData: Data("{\"error\":\"unauthorized\",\"server_time_ms\":1800000012345}".utf8),
        localTimeMilliseconds: 1_800_000_000_000
    ) == nil,
    "ordinary authentication failures cannot change the SDK clock"
)

// ── Host resilience when TrackHub is unavailable ────────────────────────────
let outageToken = "outage-\(UUID().uuidString)"
let outageIngestToken = "outage-test-ingest-token"
let outageNamespace = TrackHub.offlineQueueNamespace(
    for: outageToken,
    ingestToken: outageIngestToken
)
let outageDirectory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? FileManager.default.temporaryDirectory).appendingPathComponent("TrackHub", isDirectory: true)
let outageURL = outageDirectory.appendingPathComponent("trackhub_queue_\(outageNamespace).json")
try? FileManager.default.removeItem(at: outageURL)
let publicCallStarted = Date()
var outageConfig = TrackHubConfig(
    sdkKey: sdkKey(
        endpoint: "http://127.0.0.1:9",
        ingestToken: outageIngestToken,
        sdkSecret: "outage-test-sdk-secret"
    ),
    environment: .testLab(token: outageToken)
)
outageConfig.debugLogging = true
MainActor.assumeIsolated { TrackHub.start(outageConfig) }
TrackHub.trackEvent("invalid_payload", callbackParams: ["not_finite": Double.nan])
for index in 0..<25 { TrackHub.trackEvent("offline_\(index)") }
check(
    Date().timeIntervalSince(publicCallStarted) < 1,
    "public tracking calls stay non-blocking while TrackHub is unavailable"
)
let outageDeadline = Date().addingTimeInterval(5)
var persistedTrackCount = 0
while Date() < outageDeadline {
    let snapshot = EventQueue(url: outageURL)
    persistedTrackCount = snapshot.items.filter { $0.path == "sdk/track" }.count
    if persistedTrackCount >= 25 { break }
    Thread.sleep(forTimeInterval: 0.025)
}
check(
    persistedTrackCount >= 25,
    "an unavailable TrackHub server cannot prevent events reaching durable storage"
)
check(
    !TrackHub.runtimeCircuitOpenForTesting(),
    "an unavailable TrackHub server does not open the runtime circuit"
)
try? FileManager.default.removeItem(at: outageURL)

let productionQueue = TrackHub.offlineQueueNamespace(for: nil)
let testQueueA = TrackHub.offlineQueueNamespace(for: "test-run-token-with-enough-entropy-a")
let testQueueB = TrackHub.offlineQueueNamespace(for: "test-run-token-with-enough-entropy-b")
check(productionQueue == "production", "production uses the stable offline queue namespace")
check(testQueueA.hasPrefix("test-") && testQueueA != testQueueB,
      "Test Lab runs use isolated token-hash queue namespaces")
check(!testQueueA.contains("test-run-token"), "the raw Test Lab token is not written into the queue filename")

// ── Adjust-style first-session ATT wait ─────────────────────────────────
check(TrackHub.normalizedATTConsentWaitingInterval(-1) == 0,
      "negative ATT waiting intervals are disabled")
check(TrackHub.normalizedATTConsentWaitingInterval(.infinity) == 0,
      "non-finite ATT waiting intervals are disabled")
check(TrackHub.normalizedATTConsentWaitingInterval(90) == 90,
      "a valid ATT waiting interval is preserved")
check(TrackHub.normalizedATTConsentWaitingInterval(999) == 360,
      "ATT waiting interval is capped at the Adjust-compatible 360 seconds")
check(
    TrackHub.shouldDelayFirstSessionForATT(
        waitingInterval: 120,
        status: .notDetermined,
        installAlreadySent: false,
        integrationTest: false
    ),
    "a first production session waits while ATT is not determined"
)
check(
    !TrackHub.shouldDelayFirstSessionForATT(
        waitingInterval: 120,
        status: .authorized,
        installAlreadySent: false,
        integrationTest: false
    ),
    "a resolved ATT status never delays the first session"
)
check(
    !TrackHub.shouldDelayFirstSessionForATT(
        waitingInterval: 120,
        status: .notDetermined,
        installAlreadySent: true,
        integrationTest: false
    ),
    "ATT waiting applies only before the first install report"
)
check(
    !TrackHub.shouldDelayFirstSessionForATT(
        waitingInterval: 120,
        status: .notDetermined,
        installAlreadySent: false,
        integrationTest: true
    ),
    "Integration Test Lab is never held by the ATT timer"
)

// ── Google click id extraction from a deep link ───────────────────────────────
let gc = TrackHub.parseGoogleClickIds(from: URL(string: "myapp://open?gclid=CaseSensitiveGCLID")!)
check(gc.gclid == "CaseSensitiveGCLID" && gc.gbraid == nil && gc.wbraid == nil,
      "parses gclid from a deep-link URL")
let gb = TrackHub.parseGoogleClickIds(from: URL(string: "myapp://open?gbraid=ABC123&utm_campaign=spring")!)
check(gb.gclid == nil && gb.gbraid == "ABC123" && gb.wbraid == nil, "parses gbraid from a deep-link URL")
let wb = TrackHub.parseGoogleClickIds(from: URL(string: "https://app.example.com/l?wbraid=WB9")!)
check(wb.wbraid == "WB9" && wb.gclid == nil && wb.gbraid == nil, "parses wbraid from a universal-link URL")
let none = TrackHub.parseGoogleClickIds(from: URL(string: "myapp://open?foo=bar&gbraid=")!)
check(none.gclid == nil && none.gbraid == nil && none.wbraid == nil, "empty / absent click ids are treated as nil")

let openAiOppref = TrackHub.parseOpenAiOppref(
    from: URL(string: "myapp://open?oppref=%20OpenAI-Click-123%20")!
)
check(openAiOppref == "OpenAI-Click-123", "parses and trims the OpenAI Ads oppref")
let emptyOpenAiOppref = TrackHub.parseOpenAiOppref(
    from: URL(string: "myapp://open?oppref=%20%20")!
)
check(emptyOpenAiOppref == nil, "empty OpenAI Ads oppref is treated as nil")
let oversizedOpenAiOppref = TrackHub.parseOpenAiOppref(
    from: URL(string: "myapp://open?oppref=\(String(repeating: "x", count: 1025))")!
)
check(oversizedOpenAiOppref == nil, "oversized OpenAI Ads oppref is rejected")

let reengagementTag = TrackHub.parseAdAttributionReengagementConversionTag(
    from: URL(string: "https://app.example.com/offer?AdAttributionKitReengagementOpen=tag-123")!
)
check(reengagementTag == "tag-123", "extracts the AdAttributionKit re-engagement conversion tag")
let noReengagementTag = TrackHub.parseAdAttributionReengagementConversionTag(
    from: URL(string: "https://app.example.com/offer?AdAttributionKitReengagementOpen=")!
)
check(noReengagementTag == nil, "ignores an empty AdAttributionKit conversion tag")

// ── Purchase context: identifiers only, never client-authored money ───────────────────
let purchaseBody = TrackHub.purchaseContextBody(
    transactionId: "2000000123456789",
    productId: "com.example.monthly",
    occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
    firstOpenAt: Date(timeIntervalSince1970: 1_779_000_000)
)
check(purchaseBody["transaction_id"] as? String == "2000000123456789",
      "purchase context carries the stable transaction id")
check(purchaseBody["product_id"] as? String == "com.example.monthly",
      "purchase context carries the product id")
check((purchaseBody["install_uid"] as? String)?.isEmpty == false,
      "purchase context carries the installation scope for device erasure")
check(purchaseBody["user_id"] as? String == purchaseBody["install_uid"] as? String,
      "purchase context uses the immutable installation identity")
check(purchaseBody["first_open_at"] as? String == "2026-05-17T06:40:00Z",
      "purchase context carries the stable first-open timestamp required as fot")
check(purchaseBody["revenue_cents"] == nil && purchaseBody["currency"] == nil,
      "purchase context never carries client-authored revenue")

let correctiveGeoDefaults = UserDefaults.standard
let correctiveGeoInstallUid = purchaseBody["install_uid"] as! String
correctiveGeoDefaults.set("US", forKey: "trackhub.country_code")
correctiveGeoDefaults.set("DE", forKey: "trackhub.measurement_geo.country.v1")
correctiveGeoDefaults.set(false, forKey: "trackhub.measurement_geo.eea.v1")
correctiveGeoDefaults.set(correctiveGeoInstallUid, forKey: "trackhub.measurement_geo.install_uid.v1")
let correctiveGeoBody = TrackHub.purchaseContextBody(
    transactionId: "2000000123456790",
    productId: nil
)
check(correctiveGeoBody["country"] as? String == "US",
      "3.0.3 ignores the retired server-geo cache and keeps the explicit host fallback")
check(correctiveGeoBody["eea"] == nil,
      "3.0.3 does not copy retired cached EEA into purchase context")
for key in [
    "trackhub.country_code",
    "trackhub.measurement_geo.country.v1",
    "trackhub.measurement_geo.eea.v1",
    "trackhub.measurement_geo.install_uid.v1",
] {
    correctiveGeoDefaults.removeObject(forKey: key)
}

// ── Canonical sales funnel: stable names + placement parameter ───────────────
check(
    TrackHubSalesPlacement.allCases.map(\.rawValue) == [
        "onboarding_placement",
        "inapp_placement",
        "special_placement",
        "settings_placement",
        "on_launch_placement",
        "quick_action_placement",
        "transaction_abandonment_placement",
    ],
    "sales placement enum matches the shared portfolio contract exactly"
)

let onboardingEvent = TrackHub.salesEventPayload(
    .onboardingShown,
    placement: nil,
    callbackParams: ["flow_version": "b"]
)
check(
    onboardingEvent?.name == "ob_shown" &&
    onboardingEvent?.callbackParams["flow_version"] as? String == "b" &&
    onboardingEvent?.callbackParams["placement_name"] == nil,
    "onboarding event uses ob_shown without a placement suffix"
)

let paywallEvent = TrackHub.salesEventPayload(
    .paywallShown,
    placement: .onboarding,
    callbackParams: ["placement_name": "caller-typo", "variant": "v2"]
)
check(
    paywallEvent?.name == "pw_shown" &&
    paywallEvent?.callbackParams["placement_name"] as? String == "onboarding_placement" &&
    paywallEvent?.callbackParams["variant"] as? String == "v2",
    "paywall event keeps the stable name and canonical placement_name parameter"
)

let ctaEvent = TrackHub.salesEventPayload(
    .purchaseCtaTapped,
    placement: .transactionAbandonment
)
check(
    ctaEvent?.name == "purchase_cta_tapped" &&
    ctaEvent?.callbackParams["placement_name"] as? String == "transaction_abandonment_placement",
    "purchase CTA event carries transaction abandonment as a parameter"
)
check(
    TrackHub.salesEventPayload(.paywallShown, placement: nil) == nil,
    "placement-dependent sales events fail closed without a standard placement"
)

// ── Provider-neutral external identity namespace ────────────────────────────
check(
    TrackHub.normalizedExternalProviderForTesting(" Apphud ") == "apphud",
    "Apphud identity is provider-scoped without importing ApphudSDK"
)
check(
    TrackHub.normalizedExternalProviderForTesting("revenuecat") == "revenuecat",
    "RevenueCat identity is an independent provider namespace"
)
check(
    TrackHub.normalizedExternalProviderForTesting("custom:billing_v2") == "custom:billing_v2" &&
    TrackHub.normalizedExternalProviderForTesting("custom:bad value") == nil,
    "custom provider names are bounded and fail closed"
)

print(failures == 0 ? "\nAll Swift tests passed (incl. signature parity)" : "\n\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
