import Foundation
import TrackHub

// E2E smoke of the SDK core against a live TrackHub deployment.
// Network paths are identical to iOS; SKAdNetwork calls are no-ops off-device.
// Usage: swift run live-check https://postbacks.example.com <ingest-token>

let args = CommandLine.arguments
guard args.count >= 3, let endpoint = URL(string: args[1]) else {
    print("usage: live-check <endpoint> <ingest-token>")
    exit(1)
}

// fresh run every time: clear the install-sent flag and the cached schema
UserDefaults.standard.removeObject(forKey: "trackhub.install_sent")
UserDefaults.standard.removeObject(forKey: "trackhub.cv_schema")

let userId = "sdk-live-check-\(Int.random(in: 100_000...999_999))"
print("userId: \(userId)")

TrackHub.configure(endpoint: endpoint, ingestToken: args[2], userId: userId, debug: true)
Thread.sleep(forTimeInterval: 4) // let install report + schema fetch complete

TrackHub.track("trial_started")
TrackHub.track("trial_converted", revenueCents: 750)
Thread.sleep(forTimeInterval: 2)
print("live-check finished")
