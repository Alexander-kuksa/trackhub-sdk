import Foundation
import XCTest
@testable @_spi(Testing) import TrackHub

final class TrackHubTests: XCTestCase {
    func testSdkKeyDecodesOnlyTheVersionedHttpsEnvelope() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "e": "https://measurement.example.com",
            "t": "https://postbacks.example.com",
            "i": "ingest-token-with-enough-entropy",
            "s": "sdk-secret-with-enough-entropy",
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = try XCTUnwrap(DecodedTrackHubSdkKey.decode("thcfg_v1_" + encoded))
        XCTAssertEqual(decoded.endpoint.absoluteString, "https://measurement.example.com")
        XCTAssertEqual(decoded.trackingEndpoint?.absoluteString, "https://postbacks.example.com")
        XCTAssertEqual(decoded.ingestToken, "ingest-token-with-enough-entropy")
        XCTAssertNil(DecodedTrackHubSdkKey.decode("thcfg_v2_" + encoded))
    }

    func testSdkKeyRejectsUnsafeTrackingEndpoint() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "e": "https://measurement.example.com",
            "t": "http://tracking.example.com",
            "i": "ingest-token-with-enough-entropy",
            "s": "sdk-secret-with-enough-entropy",
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNil(DecodedTrackHubSdkKey.decode("thcfg_v1_" + encoded))
    }

    func testServerPrivacyStopRequiresExplicitErasureError() {
        XCTAssertTrue(TrackHub.isServerPrivacyStop(Data("{\"error\":\"device_erased\"}".utf8)))
        XCTAssertTrue(TrackHub.isServerPrivacyStop(Data("{\"error\":\"privacy_erased\"}".utf8)))
        XCTAssertFalse(TrackHub.isServerPrivacyStop(Data("{\"error\":\"invalid_payload\"}".utf8)))
        XCTAssertFalse(TrackHub.isServerPrivacyStop(nil))
    }

    func testInstallCredentialIsOpaqueAndInstallationScoped() {
        let credential = "thic_v1_" + String(repeating: "A", count: 43)
        XCTAssertTrue(InstallCredentialStore.isValid(credential))
        XCTAssertFalse(InstallCredentialStore.isValid("thic_v1_short"))
        XCTAssertNotEqual(
            InstallCredentialStore.account(ingestToken: "token-a", installUid: "install-a"),
            InstallCredentialStore.account(ingestToken: "token-a", installUid: "install-b")
        )
    }

    func testOfflineQueuesAreAppScoped() {
        XCTAssertNotEqual(
            TrackHub.offlineQueueNamespace(for: nil, ingestToken: "app-token-a-with-enough-entropy"),
            TrackHub.offlineQueueNamespace(for: nil, ingestToken: "app-token-b-with-enough-entropy")
        )
    }

    func testConfigDescriptionRedactsCredentialsAndIdentifiers() {
        let sdkKey = "thcfg_v1_secret-material"
        let testToken = "test-lab-token-that-must-not-be-logged"
        let firebaseId = "firebase-install-identifier"
        var config = TrackHubConfig(sdkKey: sdkKey, environment: .testLab(token: testToken))
        config.firebaseAppInstanceId = firebaseId
        config.googleOnDeviceMeasurementInfo = "odm-sensitive-payload"

        let rendered = config.description
        XCTAssertFalse(rendered.contains(sdkKey))
        XCTAssertFalse(rendered.contains(testToken))
        XCTAssertFalse(rendered.contains(firebaseId))
        XCTAssertFalse(rendered.contains("odm-sensitive-payload"))
        XCTAssertTrue(rendered.contains("sdkKey=<redacted>"))
        XCTAssertTrue(rendered.contains("testLab(<redacted>)"))
    }

    func testRetryIsBoundedAndClockSkewRequiresTheExplicitServerError() throws {
        XCTAssertEqual(TrackHub.retryDelay(attempt: 99, jitter: 1), 300)
        let response = try JSONSerialization.data(withJSONObject: [
            "error": "clock_skew",
            "server_time_ms": 1_800_000_012_345 as Int64,
        ])
        XCTAssertEqual(
            TrackHub.serverClockOffset(
                responseData: response,
                localTimeMilliseconds: 1_800_000_000_000
            ),
            12_345
        )
        XCTAssertNil(
            TrackHub.serverClockOffset(
                responseData: Data("{\"error\":\"unauthorized\",\"server_time_ms\":1800000012345}".utf8),
                localTimeMilliseconds: 1_800_000_000_000
            )
        )
    }

    func testCorruptQueueIsQuarantinedInsteadOfThrowing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackhub-xctest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        try Data("not-json".utf8).write(to: file)

        let queue = EventQueue(url: file)
        XCTAssertTrue(queue.items.isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("queue.json.corrupt-") }
        XCTAssertTrue(quarantined)
    }

    func testPrivacyRequestBeforeStartIsDurable() {
        let defaults = UserDefaults.standard
        let disabledKey = "trackhub.privacy_disabled.v2"
        let pendingKey = "trackhub.privacy_pending.v2"
        let installKey = "trackhub.install_uid"
        defaults.removeObject(forKey: disabledKey)
        defaults.removeObject(forKey: pendingKey)
        defaults.removeObject(forKey: installKey)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let file = root
            .appendingPathComponent("TrackHub", isDirectory: true)
            .appendingPathComponent("trackhub_privacy_v2.json")
        try? FileManager.default.removeItem(at: file)
        defer {
            defaults.removeObject(forKey: disabledKey)
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: installKey)
            try? FileManager.default.removeItem(at: file)
        }

        TrackHub.gdprForgetMe()
        XCTAssertTrue(defaults.bool(forKey: disabledKey))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path)
                || defaults.data(forKey: pendingKey) != nil
        )
    }
}
