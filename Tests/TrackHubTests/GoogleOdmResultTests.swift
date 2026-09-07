import Foundation
import XCTest
import TrackHub

final class GoogleOdmResultTests: XCTestCase {
    func testProviderOutcomeClassificationNeverPersistsErrorDetails() {
        let secret = "private-url-and-token"
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: secret])
        let other = NSError(domain: "provider-domain", code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        XCTAssertEqual(TrackHubGoogleOdmResult.fromProvider(info: nil, error: network).diagnosticReason, "odm_network_error")
        XCTAssertEqual(TrackHubGoogleOdmResult.fromProvider(info: nil, error: other).diagnosticReason, "odm_provider_error")
        for result in [TrackHubGoogleOdmResult.available(secret), .fromProvider(info: secret, error: network), .fromProvider(info: nil, error: other)] {
            XCTAssertFalse(String(describing: result).contains(secret))
            XCTAssertFalse(String(reflecting: result).contains(secret))
        }
    }

    func testEmptyUnsupportedAndOversizedAreNotSuccessfulODM() {
        for info in [nil, ""] as [String?] {
            XCTAssertEqual(TrackHubGoogleOdmResult.fromProvider(info: info, error: nil).diagnosticReason, "odm_empty")
        }
        XCTAssertEqual(TrackHubGoogleOdmResult.unsupported.diagnosticReason, "odm_unsupported")
        let oversized = TrackHubGoogleOdmResult.available(String(repeating: "x", count: 4097))
        XCTAssertNil(oversized.info)
        XCTAssertEqual(oversized.diagnosticReason, "odm_provider_error")
    }

    func testErrorWithPartialInfoNeverBecomesAnAvailableSignal() {
        let result = TrackHubGoogleOdmResult.fromProvider(info: "partial", error: NSError(domain: "provider", code: 1))
        XCTAssertNil(result.info)
        XCTAssertEqual(result.diagnosticReason, "odm_provider_error")
        XCTAssertEqual(TrackHubGoogleOdmResult.available("opaque-test-info").info, "opaque-test-info")
    }

    func testConfigTypedProviderDescriptionDoesNotExposeResults() {
        var config = TrackHubConfig(sdkKey: "private-key")
        config.googleOnDeviceMeasurementResultProvider = { _, done in done(.available("private-info")) }
        XCTAssertTrue(config.description.contains("googleOnDeviceMeasurementResultProvider=true"))
        XCTAssertFalse(config.description.contains("private-info"))
        XCTAssertFalse(config.description.contains("private-key"))
    }
}
