import Foundation
import XCTest

@testable @_spi(Testing) import TrackHub
@testable import TrackHubGoogleODM

@MainActor
private final class AppleAPISpy: AppleAttributionAPI {
  var registrations: [String] = []
  var skanUpdates: [ConversionUpdate] = []
  var aakUpdates: [(ConversionUpdate, AdAttributionConversionTarget, String?)] = []
  var suspendAAK = false
  var aakEntered: (() -> Void)?
  var aakContinuation: CheckedContinuation<Void, Never>?

  func registerSKAN() { registrations.append("skan") }
  func registerAAK() async { registrations.append("aak") }
  func updateSKAN(_ update: ConversionUpdate) { skanUpdates.append(update) }
  func updateAAK(_ update: ConversionUpdate, target: AdAttributionConversionTarget, tag: String?)
    async
  {
    aakUpdates.append((update, target, tag))
    if suspendAAK {
      await withCheckedContinuation { continuation in
        aakContinuation = continuation
        aakEntered?()
      }
    }
  }
}

final class AppleAttributionWriterTests: XCTestCase {
  private let update = ConversionUpdate(fine: 37, coarse: "high", lockWindow: true)

  func testDefaultIsActiveAndModeDoesNotChangeMeasurementConfiguration() {
    var config = TrackHubConfig(sdkKey: "redacted")
    XCTAssertEqual(config.appleAttributionMode, .active)
    config.appleAttributionMode = .passive
    XCTAssertEqual(config.attConsentWaitingInterval, 120)
    XCTAssertEqual(config.googleOnDeviceMeasurementTimeout, 5)
    XCTAssertEqual(config.googleAdsConsent.adUserData, .unknown)
    XCTAssertEqual(config.environment, .production)
    XCTAssertTrue(config.description.contains("appleAttributionMode=passive"))
    XCTAssertFalse(config.description.contains("sdkKey=redacted"))
  }

  @MainActor func testGoogleBridgeKeepsPassiveModeAndAddsOdmProvider() async {
    var config = TrackHubConfig(sdkKey: "redacted")
    config.appleAttributionMode = .passive
    config.googleAdsConsent.adUserData = .denied
    let automatic = TrackHubGoogleODM.configurationWithDefaultProvider(config)
    XCTAssertEqual(automatic.appleAttributionMode, .passive)
    XCTAssertEqual(automatic.googleAdsConsent.adUserData, .denied)
    XCTAssertNotNil(automatic.googleOnDeviceMeasurementResultProvider)

    // Passive does not suppress a custom provider or substitute a Google
    // runtime for the host's explicitly selected provider.
    config.googleOnDeviceMeasurementResultProvider = { _, completion in
      completion(.available("test-only-opaque-value"))
    }
    let custom = TrackHubGoogleODM.configurationWithDefaultProvider(config)
    let completed = expectation(description: "ODM provider still called")
    custom.googleOnDeviceMeasurementResultProvider?(Date()) { result in
      XCTAssertEqual(result.info, "test-only-opaque-value")
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 2)
  }

  @MainActor func testPassiveRejectsRegistrationAndAllUpdateTargetsAtNativeBoundary() async {
    let api = AppleAPISpy()
    let writer = AppleAttributionWriter(api: api)
    XCTAssertNil(writer.configure(mode: .passive, integrationTest: false))
    let unauthorized = AppleAttributionPermit()
    await writer.register(permit: unauthorized)
    for target in [AdAttributionConversionTarget.all, .install, .reengagement] {
      await writer.apply(update, target: target, tag: "test-tag", permit: unauthorized)
    }
    XCTAssertTrue(api.registrations.isEmpty)
    XCTAssertTrue(api.skanUpdates.isEmpty)
    XCTAssertTrue(api.aakUpdates.isEmpty)
  }

  @MainActor func testActiveRegistersAndPreservesFineCoarseLockTargetAndTag() async throws {
    let api = AppleAPISpy()
    let writer = AppleAttributionWriter(api: api)
    let permit = try XCTUnwrap(writer.configure(mode: .active, integrationTest: false))
    await writer.register(permit: permit)
    for target in [AdAttributionConversionTarget.all, .install, .reengagement] {
      await writer.apply(update, target: target, tag: "test-tag", permit: permit)
    }
    XCTAssertEqual(api.registrations, ["skan", "aak"])
    XCTAssertEqual(api.skanUpdates, [update, update, update])
    XCTAssertEqual(api.aakUpdates.map { $0.0 }, [update, update, update])
    XCTAssertEqual(api.aakUpdates.map { $0.1 }, [.all, .install, .reengagement])
    XCTAssertEqual(api.aakUpdates.map { $0.2 }, ["test-tag", "test-tag", "test-tag"])
  }

  @MainActor func testQueuedActiveWorkCannotWriteAfterPassiveStart() async throws {
    let api = AppleAPISpy()
    let writer = AppleAttributionWriter(api: api)
    let oldPermit = try XCTUnwrap(writer.configure(mode: .active, integrationTest: false))
    XCTAssertNil(writer.configure(mode: .passive, integrationTest: false))
    await writer.register(permit: oldPermit)
    await writer.apply(update, target: .install, tag: nil, permit: oldPermit)
    XCTAssertTrue(api.registrations.isEmpty)
    XCTAssertTrue(api.skanUpdates.isEmpty)
    XCTAssertTrue(api.aakUpdates.isEmpty)
    // A repeated start with an untouched/default config must not re-enable.
    XCTAssertNil(writer.configure(mode: .active, integrationTest: false))
  }

  @MainActor func testEachStartInvalidatesOldCallbacksIncludingTestLab() async throws {
    let api = AppleAPISpy()
    let writer = AppleAttributionWriter(api: api)
    let old = try XCTUnwrap(writer.configure(mode: .active, integrationTest: false))
    XCTAssertNil(writer.configure(mode: .active, integrationTest: true))
    await writer.register(permit: old)
    let current = try XCTUnwrap(writer.configure(mode: .active, integrationTest: false))
    await writer.apply(update, target: .all, tag: nil, permit: old)
    XCTAssertTrue(api.registrations.isEmpty)
    XCTAssertTrue(api.aakUpdates.isEmpty)
    await writer.apply(update, target: .all, tag: nil, permit: current)
    XCTAssertEqual(api.skanUpdates, [update])
  }

  @MainActor func testSlowAAKDoesNotBlockSKANAndPassiveRejectsLaterWork() async throws {
    let api = AppleAPISpy()
    api.suspendAAK = true
    let writer = AppleAttributionWriter(api: api)
    let permit = try XCTUnwrap(writer.configure(mode: .active, integrationTest: false))
    let entered = expectation(description: "AAK call entered")
    api.aakEntered = { entered.fulfill() }
    let operation = Task { @MainActor in
      await writer.apply(update, target: .install, tag: nil, permit: permit)
    }
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertEqual(api.skanUpdates, [update], "SKAN must not wait for AAK completion")
    XCTAssertNil(writer.configure(mode: .passive, integrationTest: false))
    await writer.apply(update, target: .install, tag: nil, permit: permit)
    api.aakContinuation?.resume()
    await operation.value
    // Already-invoked Apple work cannot be undone, but it grants no right
    // to invoke another update after the mode has changed.
    XCTAssertEqual(api.aakUpdates.count, 1)
    XCTAssertEqual(api.skanUpdates, [update])
  }

  @MainActor func testPrivacyOrRuntimeStopSuppressesAnOtherwiseValidPermit() async throws {
    let api = AppleAPISpy()
    var stopped = false
    let writer = AppleAttributionWriter(api: api, isSuppressed: { stopped })
    let permit = try XCTUnwrap(writer.configure(mode: .active, integrationTest: false))
    stopped = true
    await writer.register(permit: permit)
    await writer.apply(update, target: .reengagement, tag: "tag", permit: permit)
    XCTAssertTrue(api.registrations.isEmpty)
    XCTAssertTrue(api.aakUpdates.isEmpty)
    XCTAssertTrue(api.skanUpdates.isEmpty)
  }

  @MainActor func testNewProcessCanStartActiveAfterAPassiveProcess() throws {
    let previousProcess = AppleAttributionWriter(api: AppleAPISpy())
    XCTAssertNil(previousProcess.configure(mode: .passive, integrationTest: false))
    let nextProcess = AppleAttributionWriter(api: AppleAPISpy())
    XCTAssertNotNil(nextProcess.configure(mode: .active, integrationTest: false))
  }
}
