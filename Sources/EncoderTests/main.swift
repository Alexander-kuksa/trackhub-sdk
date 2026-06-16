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
// HMAC-SHA256("parity" key, "123.tok.{\"a\":1}") must match the Node vector.
let sigMsg = "123.tok.{\"a\":1}"
let sigMac = HMAC<SHA256>.authenticationCode(for: Data(sigMsg.utf8), using: SymmetricKey(data: Data("parity".utf8)))
let sigHex = sigMac.map { String(format: "%02x", $0) }.joined()
check(sigHex == "40d56064e34d01661d8d5f7d8a15d1cab9fe32b9b1c8788cd53c19a4d5a755c5",
      "SDK signature HMAC matches the server vector")

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

// ── Google click id extraction from a deep link (gbraid / wbraid) ─────────────
let gb = TrackHub.parseGoogleClickIds(from: URL(string: "myapp://open?gbraid=ABC123&utm_campaign=spring")!)
check(gb.gbraid == "ABC123" && gb.wbraid == nil, "parses gbraid from a deep-link URL")
let wb = TrackHub.parseGoogleClickIds(from: URL(string: "https://app.example.com/l?wbraid=WB9")!)
check(wb.wbraid == "WB9" && wb.gbraid == nil, "parses wbraid from a universal-link URL")
let none = TrackHub.parseGoogleClickIds(from: URL(string: "myapp://open?foo=bar&gbraid=")!)
check(none.gbraid == nil && none.wbraid == nil, "empty / absent click ids are treated as nil")

print(failures == 0 ? "\nAll Swift tests passed (incl. signature parity)" : "\n\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
