import Foundation
import TrackHub

// E2E smoke of the SDK core against a live TrackHub deployment.
// Network paths are identical to iOS; SKAdNetwork calls are no-ops off-device.
// Usage: swift run live-check https://postbacks.example.com <ingest-token> <sdk-secret> [test-run-token]

let passive = CommandLine.arguments.contains("--passive")
let loopbackFixture = CommandLine.arguments.contains("--loopback-fixture")
let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
guard args.count >= 4, let endpoint = URL(string: args[1]) else {
    print("usage: live-check <endpoint> <ingest-token> <sdk-secret> [test-run-token] [--passive] [--loopback-fixture]")
    exit(1)
}
guard !loopbackFixture || (endpoint.host == "127.0.0.1" && endpoint.scheme == "http") else {
    fatalError("Synthetic fixtures are restricted to the local loopback receiver")
}

// fresh run every time: clear the install-sent flag and the cached schema
UserDefaults.standard.removeObject(forKey: "trackhub.install_sent")
UserDefaults.standard.removeObject(forKey: "trackhub.cv_schema")

let sdkKeyPayload = try JSONSerialization.data(withJSONObject: [
    "e": endpoint.absoluteString,
    "i": args[2],
    "s": args[3],
])
let sdkKey = "thcfg_v1_" + sdkKeyPayload.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")

var configuration = TrackHubConfig(
    sdkKey: sdkKey,
    environment: args.count >= 5 ? .testLab(token: args[4]) : .production
)
configuration.debugLogging = true
configuration.appleAttributionMode = passive ? .passive : .active
if loopbackFixture {
    UserDefaults.standard.removeObject(forKey: "trackhub.google_odm_info")
    configuration.googleOnDeviceMeasurementResultProvider = { _, completion in
        completion(.available("loopback-odm-fixture"))
    }
}
MainActor.assumeIsolated { TrackHub.start(configuration) }
RunLoop.main.run(until: Date().addingTimeInterval(4))

// trackEvent → POST /sdk/track (plus the on-device SKAN update, no-op off-device).
// Revenue is intentionally absent: Apphud/S2S is authoritative for money.
TrackHub.trackEvent("trial_started")
TrackHub.trackEvent("paywall_viewed")
if loopbackFixture {
    TrackHub.setGoogleClickIds(gclid: "loopback-click-fixture")
    // A fresh test identity avoids the SDK's intentional unchanged-identity
    // deduplication between consecutive CLI runs.
    TrackHub.setExternalIdentity(provider: "custom:smoke", userId: "loopback-user-\(UUID().uuidString)")
    TrackHub.trackPurchaseObserved(transactionId: "loopback-transaction-fixture", productId: "loopback-product")
}
RunLoop.main.run(until: Date().addingTimeInterval(4))
print("live-check finished")
