import Foundation
import TrackHub

// E2E smoke of the SDK core against a live TrackHub deployment.
// Network paths are identical to iOS; SKAdNetwork calls are no-ops off-device.
// Usage: swift run live-check https://postbacks.example.com <ingest-token> <sdk-secret> [test-run-token]

let args = CommandLine.arguments
guard args.count >= 4, let endpoint = URL(string: args[1]) else {
    print("usage: live-check <endpoint> <ingest-token> <sdk-secret> [test-run-token]")
    exit(1)
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
MainActor.assumeIsolated { TrackHub.start(configuration) }
Thread.sleep(forTimeInterval: 4) // let install report + schema fetch complete

// trackEvent → POST /sdk/track (plus the on-device SKAN update, no-op off-device).
// Revenue is intentionally absent: Apphud/S2S is authoritative for money.
TrackHub.trackEvent("trial_started")
TrackHub.trackEvent("paywall_viewed")
Thread.sleep(forTimeInterval: 2)
print("live-check finished")
