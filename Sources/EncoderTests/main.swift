import Foundation
import CryptoKit
@_spi(Testing) import TrackHub

// Encoder parity tests (mirror of tests/skan.test.ts on the backend).
// Run with: swift run encoder-tests — exits non-zero on any failure.

var failures = 0

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

// SDK Signature HMAC parity with the server (tests/sdk-signature.test.ts):
// HMAC-SHA256("parity" key, v2 endpoint-bound message) must match Node/Android.
let sigMsg = "123.tok.install.{\"a\":1}"
let sigMac = HMAC<SHA256>.authenticationCode(for: Data(sigMsg.utf8), using: SymmetricKey(data: Data("parity".utf8)))
let sigHex = sigMac.map { String(format: "%02x", $0) }.joined()
check(sigHex == "48bd3ea5529853b246d18a578d1ce79aa50c2d3e7f69663b233bd696c5c8a91d",
      "SDK signature HMAC matches the server vector")

check(TrackHub.normalizedCountryCode(" de ") == "DE",
      "explicit country code is normalized to ISO uppercase")
check(TrackHub.normalizedCountryCode("XX") == nil && TrackHub.normalizedCountryCode("Europe") == nil,
      "unknown and non-ISO country values are rejected")

// ── Session coalescing (60s timeout, monotonic sequence) ──────────────────────
let suiteName = "trackhub.parity.session"
let suite = UserDefaults(suiteName: suiteName)!
suite.removePersistentDomain(forName: suiteName)
var sidN = 0
let tracker = SessionTracker(timeout: 60, defaults: suite, uuid: { sidN += 1; return "sid\(sidN)" })
let base = Date(timeIntervalSince1970: 1_000_000)
let firstSession = tracker.foreground(at: base)
check(firstSession?.sessionNum == 1 && firstSession?.sessionUid == "sid1",
      "first foreground starts session 1")
tracker.background(at: base.addingTimeInterval(10))
check(tracker.foreground(at: base.addingTimeInterval(40)) == nil,
      "foreground within 60s coalesces into the same session")
tracker.background(at: base.addingTimeInterval(50))
check(tracker.foreground(at: base.addingTimeInterval(200))?.sessionNum == 2,
      "foreground after a >60s gap starts session 2 (monotonic sequence)")
let forcedSession = tracker.forceForeground(at: base.addingTimeInterval(201))
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
    userId: "apphud-user",
    occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
    firstOpenAt: Date(timeIntervalSince1970: 1_779_000_000)
)
check(purchaseBody["transaction_id"] as? String == "2000000123456789",
      "purchase context carries the stable transaction id")
check(purchaseBody["product_id"] as? String == "com.example.monthly",
      "purchase context carries the product id")
check(purchaseBody["first_open_at"] as? String == "2026-05-17T06:40:00Z",
      "purchase context carries the stable first-open timestamp required as fot")
check(purchaseBody["revenue_cents"] == nil && purchaseBody["currency"] == nil,
      "purchase context never carries client-authored revenue")

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

// ── Apphud attribution bridge revision dedup ──────────────────────────────────────
let attributionSuiteName = "trackhub.parity.apphud-attribution"
let attributionDefaults = UserDefaults(suiteName: attributionSuiteName)!
attributionDefaults.removePersistentDomain(forName: attributionSuiteName)
check(
    TrackHub.shouldDeliverApphudAttribution(
        revision: "tp-1",
        userId: "apphud-user",
        defaults: attributionDefaults
    ),
    "an unseen Apphud attribution revision is deliverable"
)
TrackHub.markApphudAttributionDelivered(
    revision: "tp-1",
    userId: "apphud-user",
    defaults: attributionDefaults
)
check(
    !TrackHub.shouldDeliverApphudAttribution(
        revision: "tp-1",
        userId: "apphud-user",
        defaults: attributionDefaults
    ),
    "an acknowledged Apphud attribution revision is suppressed"
)
check(
    TrackHub.shouldDeliverApphudAttribution(
        revision: "tp-2",
        userId: "apphud-user",
        defaults: attributionDefaults
    ),
    "a changed Apphud attribution revision is deliverable"
)
attributionDefaults.removePersistentDomain(forName: attributionSuiteName)

print(failures == 0 ? "\nAll Swift tests passed (incl. signature parity)" : "\n\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
