import Foundation
import XCTest
@testable @_spi(Testing) import TrackHub

final class FirstOpenReportEnrichmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let vendorID = "11111111-1111-4111-8111-111111111111"
    private let advertisingID = "22222222-2222-4222-8222-222222222222"
    private var eligibility: FirstOpenReportEnrichment {
        FirstOpenReportEnrichment(installUid: "install-a", expiresAt: now.addingTimeInterval(600), allowAdvertisingId: true)
    }
    private var signals: [String: Any] {
        ["odm_info": "opaque-test-info", "device_id": advertisingID, "device_id_type": "idfa", "limit_ad_tracking": false]
    }
    private func report(path: String = "sdk/session", metadata: FirstOpenReportEnrichment? = nil,
                        attempts: Int = 0, dispatched: Bool = false) throws -> PendingReport {
        PendingReport(id: "report-a", path: path, body: try JSONSerialization.data(withJSONObject: [
            "install_uid": "install-a", "session_uid": "session-a", "event_id": "event-a",
            "occurred_at": "2026-09-08T00:00:00Z", "first_open_at": "2026-09-08T00:00:00Z",
            "transaction_id": "transaction-a", "value": 9.99, "currency": "USD", "gclid": "original-click",
            "device_id": vendorID, "device_id_type": "idfv", "limit_ad_tracking": true,
        ], options: .sortedKeys), createdAt: now, kind: path == "install" ? "production_install" : "session",
                      dedupeKey: "stable-key", attempts: attempts, firstOpenEnrichment: metadata, hasBeenDispatched: dispatched)
    }
    private func enrich(_ report: PendingReport, signals: [String: Any]? = nil, allowed: Bool = true,
                        time: Date? = nil, scope: String = "install-a") -> Data? {
        report.firstOpenEnrichment?.bodyForFirstDispatch(report: report, currentInstallUid: scope,
            signals: signals ?? self.signals, measurementAllowed: allowed, now: time ?? now.addingTimeInterval(5))
    }
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func withQueue(_ body: (EventQueue, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.json")
        try body(EventQueue(url: url), url)
    }

    func testHeldEventsGetSignalsWithoutChangingEventIdentityOrEconomics() throws {
        for path in FirstOpenReportEnrichment.paths {
            let original = try report(path: path, metadata: eligibility)
            var expected = try json(original.body)
            signals.forEach { expected[$0.key] = $0.value }
            let actual = try json(XCTUnwrap(enrich(original)))
            XCTAssertEqual(actual as NSDictionary, expected as NSDictionary, path)
        }
    }

    func testExplicitATTDenialAtCreationCannotBePromoted() throws {
        let denied = FirstOpenReportEnrichment(installUid: "install-a", expiresAt: now.addingTimeInterval(600), allowAdvertisingId: false)
        let result = try json(XCTUnwrap(enrich(try report(metadata: denied))))
        XCTAssertEqual(result["device_id"] as? String, vendorID)
        XCTAssertEqual(result["device_id_type"] as? String, "idfv")
        XCTAssertEqual(result["odm_info"] as? String, "opaque-test-info")
    }

    func testConsentWithdrawalStripsSignalsEvenAfterExpiry() throws {
        let original = try report(metadata: eligibility)
        let enriched = try XCTUnwrap(enrich(original))
        let pending = PendingReport(path: original.path, body: enriched, createdAt: now, firstOpenEnrichment: eligibility)
        let result = try json(XCTUnwrap(enrich(pending, allowed: false, time: now.addingTimeInterval(601))))
        for key in ["odm_info", "device_id", "device_id_type", "limit_ad_tracking"] { XCTAssertNil(result[key]) }
        XCTAssertEqual(result["session_uid"] as? String, "session-a")
    }

    func testATTRevocationCannotRetainOldIDFAWhenNoIDFVIsAvailable() throws {
        let original = try report(metadata: eligibility)
        let pending = PendingReport(path: original.path, body: try XCTUnwrap(enrich(original)), createdAt: now, firstOpenEnrichment: eligibility)
        for seconds in [6.0, 601.0] {
            let result = try json(XCTUnwrap(enrich(pending, signals: [:], time: now.addingTimeInterval(seconds))))
            XCTAssertNil(result["device_id"])
            XCTAssertNil(result["device_id_type"])
        }
    }

    func testLegacyOtherScopeExpiredRetryAndOtherPathsAreNeverEnriched() throws {
        XCTAssertNil(enrich(try report()))
        XCTAssertNil(enrich(try report(metadata: eligibility), scope: "install-b"))
        XCTAssertNil(enrich(try report(metadata: eligibility), time: now.addingTimeInterval(601)))
        XCTAssertNil(enrich(try report(metadata: eligibility), time: now.addingTimeInterval(-1)))
        XCTAssertNil(enrich(try report(metadata: eligibility, attempts: 1)))
        XCTAssertNil(enrich(try report(metadata: eligibility, dispatched: true)))
        XCTAssertNil(enrich(try report(path: "sdk/diagnostic", metadata: eligibility)))
    }

    func testInvalidAndOversizedSignalsDoNotReplaceValidSnapshot() throws {
        let original = try report(metadata: eligibility)
        for invalid in ["", "not-a-uuid", "00000000-0000-0000-0000-000000000000"] {
            let result = try json(XCTUnwrap(enrich(original, signals: ["device_id": invalid, "device_id_type": "idfa",
                "limit_ad_tracking": false, "odm_info": String(repeating: "x", count: 4097)])))
            XCTAssertEqual(result as NSDictionary, try json(original.body) as NSDictionary)
        }
    }

    func testTimeoutThenLateODMEnrichesUnsentReportsButFreezesDispatchedInstall() throws {
        try withQueue { queue, url in
            var state = GoogleOdmDeliveryState()
            let fetch = UUID()
            state.start(token: fetch, delayDelivery: true)
            XCTAssertNotNil(queue.enqueue(try report(metadata: eligibility)))
            let install = try report(path: "install", metadata: eligibility)
            // Independent dedupe key: the install must be sent before the buffered session.
            XCTAssertNotNil(queue.enqueue(PendingReport(id: "install-report", path: install.path, body: install.body,
                createdAt: now, kind: "production_install", dedupeKey: "install-key", firstOpenEnrichment: eligibility)))
            XCTAssertTrue(state.expire(token: fetch))
            let sentInstall = try XCTUnwrap(queue.prepareNextForDispatch { self.enrich($0, signals: [:]) })
            XCTAssertEqual(sentInstall.id, "install-report")
            _ = state.complete(token: fetch, privacyStopped: false, runtimeCircuitOpen: false, hasValidInfo: true)
            XCTAssertEqual(queue.prepareNextForDispatch { self.enrich($0) }?.body, sentInstall.body)
            XCTAssertTrue(queue.remove(id: sentInstall.id))
            let sentSession = try XCTUnwrap(queue.prepareNextForDispatch { self.enrich($0) })
            XCTAssertEqual(try json(sentSession.body)["odm_info"] as? String, "opaque-test-info")
            XCTAssertNil(sentSession.firstOpenEnrichment)
            XCTAssertTrue(sentSession.hasBeenDispatched)
            XCTAssertEqual(EventQueue(url: url).items.first?.body, sentSession.body)
        }
    }

    func testRetryRestartAndLateInstallReplacementKeepExactWireBytes() throws {
        try withQueue { queue, url in
            let original = try report(path: "install", metadata: eligibility)
            XCTAssertNotNil(queue.enqueue(original))
            let dispatched = try XCTUnwrap(queue.prepareNextForDispatch { self.enrich($0) })
            XCTAssertTrue(queue.markRetry(id: dispatched.id, attempts: 1, nextAttemptAt: now.addingTimeInterval(30)))
            let restarted = EventQueue(url: url)
            XCTAssertEqual(restarted.enqueue(try report(path: "install", metadata: eligibility)), original.id)
            let retry = try XCTUnwrap(restarted.prepareNextForDispatch { _ in XCTFail("Must not enrich retry"); return nil })
            XCTAssertEqual(retry.body, dispatched.body)
            XCTAssertEqual(retry.attempts, 1)
            XCTAssertEqual(retry.nextAttemptAt, now.addingTimeInterval(30))
        }
    }

    func testEnrichmentNeverEvictsOtherEventsToFitStorageBudget() throws {
        try withQueue { _, url in
            let queue = EventQueue(maxBytes: 3000, maxItemBytes: 1800, url: url)
            let original = try report(metadata: eligibility)
            XCTAssertNotNil(queue.enqueue(original))
            XCTAssertNotNil(queue.enqueue(PendingReport(path: "sdk/track", body: Data("{}".utf8))))
            let result = try XCTUnwrap(queue.prepareNextForDispatch { _ in Data(repeating: 1, count: 2000) })
            XCTAssertEqual(result.body, original.body)
            XCTAssertEqual(queue.count, 2)
        }
    }

    func testLegacyCodableWithoutNewFieldsRemainsSupported() throws {
        let original = try report(attempts: 1)
        var object = try json(JSONEncoder().encode(original))
        object.removeValue(forKey: "hasBeenDispatched")
        object.removeValue(forKey: "firstOpenEnrichment")
        let decoded = try JSONDecoder().decode(PendingReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.hasBeenDispatched)
        XCTAssertNil(decoded.firstOpenEnrichment)
        XCTAssertEqual(decoded.body, original.body)
    }

    func testCapacityFallbackCannotRestoreAnIDFAAfterConsentWithdrawal() throws {
        try withQueue { _, url in
            let queue = EventQueue(maxBytes: 3000, maxItemBytes: 1800, url: url)
            let original = try report(metadata: eligibility)
            let pending = PendingReport(path: original.path, body: try XCTUnwrap(enrich(original)), createdAt: now,
                                        firstOpenEnrichment: eligibility)
            XCTAssertNotNil(queue.enqueue(pending))
            let result = try XCTUnwrap(queue.prepareNextForDispatch(capacityFallback: { self.enrich($0, allowed: false) }) {
                self.enrich($0, signals: ["odm_info": String(repeating: "x", count: 2000)])
            })
            XCTAssertNil(try json(result.body)["device_id"])
            XCTAssertNil(try json(result.body)["odm_info"])
        }
    }

    func testFailedDurableFreezeCannotReturnAnUnpersistedWireBody() throws {
        try withQueue { queue, url in
            let original = try report(metadata: eligibility)
            XCTAssertNotNil(queue.enqueue(original))
            // Replace the dedicated test directory with a file to force failure
            // without depending on Unix permissions or the test user's UID.
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            try Data("not-a-directory".utf8).write(to: url.deletingLastPathComponent())
            XCTAssertNil(queue.prepareNextForDispatch { self.enrich($0) })
            XCTAssertTrue(queue.storageFailure)
            XCTAssertEqual(queue.items.first, original)
        }
    }
}
