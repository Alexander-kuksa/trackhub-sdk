import Foundation
import XCTest
@testable @_spi(Testing) import TrackHub

final class TrackHubTests: XCTestCase {
    func testSdkKeyDecodesOnlyTheVersionedHttpsEnvelope() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "e": "https://postbacks.example.com",
            "i": "ingest-token-with-enough-entropy",
            "s": "sdk-secret-with-enough-entropy",
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = try XCTUnwrap(DecodedTrackHubSdkKey.decode("thcfg_v1_" + encoded))
        XCTAssertEqual(decoded.endpoint.absoluteString, "https://postbacks.example.com")
        XCTAssertEqual(decoded.ingestToken, "ingest-token-with-enough-entropy")
        XCTAssertNil(DecodedTrackHubSdkKey.decode("thcfg_v2_" + encoded))
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
}
