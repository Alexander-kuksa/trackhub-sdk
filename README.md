# TrackHub iOS SDK

Lightweight Swift package: install reporting, deterministic Apple Search Ads attribution
(AdServices token, resolved server-side) and remote-controlled SKAdNetwork conversion values
(Conversion Hub — edit the schema in the TrackHub UI, devices pick it up without an app release).

> **Full step-by-step integration walkthrough (where the call goes, SwiftUI vs UIKit,
> verification, troubleshooting):** see [`INTEGRATION.md`](INTEGRATION.md).

## Install

Xcode → File → Add Package Dependencies → `https://github.com/Alexander-kuksa/trackhub-sdk` →
Dependency Rule: Up to Next Major `1.0.0`. iOS 14+, no third-party dependencies.

Swift Package Manager (`Package.swift`):

```swift
.package(url: "https://github.com/Alexander-kuksa/trackhub-sdk", from: "1.0.0")
```

## Usage

```swift
import TrackHub

// On app launch (e.g. in AppDelegate / @main init), after Apphud starts.
// Copy the exact values (incl. sdkSecret) from the app's page in TrackHub →
// SDK integration.
TrackHub.configure(
    endpoint: URL(string: "https://postbacks.example.com")!, // your ingest domain
    ingestToken: "<app ingest token from the TrackHub app page>",
    sdkSecret: "<app sdk secret>",   // optional; enables SDK Signature
    userId: Apphud.userID()          // ties installs to Apphud events
)

// App sessions are tracked automatically after configure() (DAU/WAU/MAU + retention).

// Custom events → TrackHub analytics (Engagement tab) + SKAN conversion values:
TrackHub.trackEvent("trial_started")
TrackHub.trackEvent("trial_converted", revenueCents: 999)
```

### iOS Google Ads attribution (gbraid / wbraid)

If a user arrives from a Google Ads click that carries a click id (iOS app click → `gbraid`,
web-to-app → `wbraid`), capture it from the deep link **before** `configure(...)` so it rides the
one-shot install report. TrackHub can then send the resulting purchase back to Google Ads for that
click, so Smart Bidding optimizes on it:

```swift
// In your URL handler — and, on a cold launch from a click, the launch URL:
TrackHub.handleDeepLink(url)            // pulls gbraid / wbraid from the URL query
// …or set it directly if you obtained the id another way:
TrackHub.setGoogleClickId(gbraid: "…")

TrackHub.configure(/* … */)             // call AFTER the click id is set
```

Pure SKAdNetwork installs carry no click id and stay SKAN-aggregate (Apple's privacy model).

What happens under the hood:

- **First launch:** one `POST /ingest/{token}/install` with the AdServices attribution token
  (resolved with Apple into ASA campaign / ad group / keyword ids) and any `gbraid` / `wbraid`
  set beforehand. Repeat launches are no-ops (and a failed report retries next launch).
- **Every launch:** the active conversion value schema is fetched from
  `GET /ingest/{token}/cv-schema` and cached locally.
- **`track(event, revenueCents:)`:** the event is encoded via the schema (fine value 0–63 with
  linear revenue bucketing, SKAN 4 coarse value, optional window lock) and applied through the
  best available API: `updatePostbackConversionValue(_:coarseValue:lockWindow:)` on iOS 16.1+,
  fine-only on 15.4+, legacy `updateConversionValue` on 14.x.

## Notes

- The SDK never sends events to TrackHub analytics — revenue/trial data arrives via Apphud
  webhooks. `track()` only drives SKAN conversion values on the device.
- AdServices tokens resolve on real devices only (not simulators).
- Set `debug: true` in `configure` to see `[TrackHub]` log lines.

## Development

Core logic (schema decoding + conversion value encoder) is platform-independent and covered by
a parity test suite that mirrors the backend tests:

```bash
swift run encoder-tests
```
