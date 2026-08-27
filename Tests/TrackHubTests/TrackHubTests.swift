import Foundation
import XCTest
@testable @_spi(Testing) import TrackHub

final class TrackHubTests: XCTestCase {
    func testFirstOpenDeliveryDefaultsAreBoundedAndCrashStable() {
        XCTAssertEqual(TrackHubConfig.defaultATTConsentWaitingInterval, 120)
        XCTAssertEqual(
            TrackHubConfig(sdkKey: "test").attConsentWaitingInterval,
            TrackHubConfig.defaultATTConsentWaitingInterval
        )
        XCTAssertEqual(TrackHubConfig(sdkKey: "test").googleOnDeviceMeasurementTimeout, 5)

        let firstOpen = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            TrackHub.remainingATTConsentWaitingInterval(
                waitingInterval: 120,
                firstOpenAt: firstOpen,
                now: Date(timeIntervalSince1970: 1_030)
            ),
            90
        )
        XCTAssertEqual(
            TrackHub.remainingATTConsentWaitingInterval(
                waitingInterval: 120,
                firstOpenAt: firstOpen,
                now: Date(timeIntervalSince1970: 1_121)
            ),
            0
        )
        XCTAssertEqual(
            TrackHub.remainingATTConsentWaitingInterval(
                waitingInterval: 0,
                firstOpenAt: firstOpen,
                now: firstOpen
            ),
            0
        )
    }

    func testGoogleAdsConsentIsOptionalAndDoesNotInferEitherSignal() {
        let consent = TrackHubGoogleAdsConsent()
        XCTAssertEqual(consent.adUserData, .unknown)
        XCTAssertEqual(consent.adPersonalization, .unknown)
        XCTAssertNil(consent.isEea)
    }

    func testWbraidIsAFirstClassSessionClickReference() {
        XCTAssertEqual(
            TrackHub.sessionGoogleClickIds(gclid: nil, gbraid: nil, wbraid: "WBraid-MixedCase-123"),
            ["wbraid": "WBraid-MixedCase-123"]
        )
        XCTAssertEqual(
            TrackHub.sessionGoogleClickIds(gclid: "G1", gbraid: "GB1", wbraid: "WB1"),
            ["gclid": "G1", "gbraid": "GB1", "wbraid": "WB1"]
        )
        XCTAssertTrue(
            TrackHub.sessionGoogleClickIds(gclid: nil, gbraid: nil, wbraid: "").isEmpty
        )
    }

    func testSetGoogleClickIdsPersistsWbraidForTheNextSession() {
        let defaults = UserDefaults.standard
        let durableKey = "trackhub.wbraid"
        let pendingKey = "trackhub.pending_wbraid"
        defaults.removeObject(forKey: durableKey)
        defaults.removeObject(forKey: pendingKey)
        defer {
            defaults.removeObject(forKey: durableKey)
            defaults.removeObject(forKey: pendingKey)
        }

        TrackHub.storeGoogleClickIds(gclid: nil, gbraid: nil, wbraid: "WBraid-Existing-Install")

        XCTAssertEqual(defaults.string(forKey: durableKey), "WBraid-Existing-Install")
        XCTAssertEqual(defaults.string(forKey: pendingKey), "WBraid-Existing-Install")
    }

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
        config.googleOnDeviceMeasurementInfoProvider = { _, completion in completion(nil) }

        let rendered = config.description
        XCTAssertFalse(rendered.contains(sdkKey))
        XCTAssertFalse(rendered.contains(testToken))
        XCTAssertFalse(rendered.contains(firebaseId))
        XCTAssertFalse(rendered.contains("odm-sensitive-payload"))
        XCTAssertTrue(rendered.contains("sdkKey=<redacted>"))
        XCTAssertTrue(rendered.contains("testLab(<redacted>)"))
        XCTAssertTrue(rendered.contains("googleOnDeviceMeasurementInfoProvider=true"))
    }

    func testGoogleOnDeviceMeasurementWaitIsBoundedAndOnlyRunsBeforeFirstOpen() {
        XCTAssertEqual(TrackHub.normalizedGoogleOnDeviceMeasurementWaitingInterval(-1), 0)
        XCTAssertEqual(TrackHub.normalizedGoogleOnDeviceMeasurementWaitingInterval(.infinity), 0)
        XCTAssertEqual(TrackHub.normalizedGoogleOnDeviceMeasurementWaitingInterval(3), 3)
        XCTAssertEqual(TrackHub.normalizedGoogleOnDeviceMeasurementWaitingInterval(60), 15)

        XCTAssertTrue(TrackHub.shouldFetchGoogleOnDeviceMeasurementInfo(
            hasProvider: true,
            hasExplicitInfo: false,
            hasCachedInfo: false,
            installAlreadySent: false,
            privacyStopped: false
        ))
        XCTAssertFalse(TrackHub.shouldFetchGoogleOnDeviceMeasurementInfo(
            hasProvider: true,
            hasExplicitInfo: false,
            hasCachedInfo: false,
            installAlreadySent: true,
            privacyStopped: false
        ))
        XCTAssertFalse(TrackHub.shouldFetchGoogleOnDeviceMeasurementInfo(
            hasProvider: true,
            hasExplicitInfo: true,
            hasCachedInfo: false,
            installAlreadySent: false,
            privacyStopped: false
        ))
        XCTAssertFalse(TrackHub.shouldFetchGoogleOnDeviceMeasurementInfo(
            hasProvider: true,
            hasExplicitInfo: false,
            hasCachedInfo: false,
            installAlreadySent: false,
            privacyStopped: true
        ))
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

    func testUnwritableQueueSignalsStorageFailureWithoutThrowing() {
        let queue = EventQueue(url: URL(fileURLWithPath: "/dev/null/trackhub-queue.json"))
        XCTAssertNil(queue.enqueue(PendingReport(path: "sdk/track", body: Data("{}".utf8))))
        XCTAssertTrue(queue.storageFailure)
    }

    func testExternalIdentityWaitsForProductionInstallAcknowledgement() {
        XCTAssertFalse(TrackHub.shouldEnqueueExternalIdentity(
            installAcknowledged: false,
            integrationTest: false
        ))
        XCTAssertTrue(TrackHub.shouldEnqueueExternalIdentity(
            installAcknowledged: true,
            integrationTest: false
        ))
        XCTAssertTrue(TrackHub.shouldEnqueueExternalIdentity(
            installAcknowledged: false,
            integrationTest: true
        ))
    }

    func testLegacyIdentityHeadLetsProductionInstallSelfHealFirst() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackhub-ordering-xctest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = EventQueue(url: directory.appendingPathComponent("queue.json"))
        let identity = PendingReport(
            path: "sdk/identity",
            body: Data("{}".utf8),
            kind: "external_identity"
        )
        let event = PendingReport(
            path: "sdk/track",
            body: Data("{}".utf8),
            kind: "event"
        )
        let install = PendingReport(
            path: "sdk/install",
            body: Data("{}".utf8),
            kind: "production_install"
        )
        XCTAssertNotNil(queue.enqueue(identity))
        XCTAssertNotNil(queue.enqueue(event))
        XCTAssertNotNil(queue.enqueue(install))

        XCTAssertEqual(queue.nextForDelivery?.id, install.id)
        XCTAssertTrue(queue.remove(id: install.id))
        XCTAssertEqual(queue.nextForDelivery?.id, identity.id)
    }

    func testFirstSessionBufferedByConsentWaitCannotPassTheInstallAnchor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackhub-first-open-ordering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = EventQueue(url: directory.appendingPathComponent("queue.json"))
        let session = PendingReport(path: "sdk/session", body: Data("{}".utf8), kind: "session")
        let event = PendingReport(path: "sdk/track", body: Data("{}".utf8), kind: "event")
        let install = PendingReport(
            path: "install",
            body: Data("{}".utf8),
            kind: "production_install",
            dedupeKey: "install"
        )
        XCTAssertNotNil(queue.enqueue(session))
        XCTAssertNotNil(queue.enqueue(event))
        XCTAssertNotNil(queue.enqueue(install))

        XCTAssertEqual(queue.nextForDelivery?.id, install.id)
        XCTAssertTrue(queue.remove(id: install.id))
        XCTAssertEqual(queue.nextForDelivery?.id, session.id)
    }

    func testRuntimeCircuitIsProcessLocalAndResettableForTests() {
        TrackHub.resetRuntimeCircuitForTesting()
        XCTAssertFalse(TrackHub.runtimeCircuitOpenForTesting())
        TrackHub.openRuntimeCircuitForTesting()
        XCTAssertTrue(TrackHub.runtimeCircuitOpenForTesting())
        XCTAssertEqual(TrackHub.runtimeCircuitMarkerReasonForTesting(), "algorithm")
        TrackHub.resetRuntimeCircuitForTesting()
        XCTAssertFalse(TrackHub.runtimeCircuitOpenForTesting())
        XCTAssertNil(TrackHub.runtimeCircuitMarkerReasonForTesting())
    }

    func testCorrectiveUpgradeDeletesRetiredMeasurementGeographyState() {
        let defaults = UserDefaults.standard
        let keys: [String: Any] = [
            "trackhub.measurement_geo.country.v1": "DE",
            "trackhub.measurement_geo.eea.v1": true,
            "trackhub.measurement_geo.install_uid.v1": "test-install",
            "trackhub.measurement_geo.refresh_terminal.v1": "test-install",
        ]
        for (key, value) in keys { defaults.set(value, forKey: key) }

        TrackHub.purgeRetiredMeasurementGeographyState()

        for key in keys.keys { XCTAssertNil(defaults.object(forKey: key)) }
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
            TrackHub.resetRuntimeCircuitForTesting()
            defaults.removeObject(forKey: disabledKey)
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: installKey)
            try? FileManager.default.removeItem(at: file)
        }

        TrackHub.openRuntimeCircuitForTesting()
        TrackHub.gdprForgetMe()
        XCTAssertTrue(defaults.bool(forKey: disabledKey))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path)
                || defaults.data(forKey: pendingKey) != nil
        )
    }
}
