# TrackHub iOS SDK

Lightweight Swift package: install/session reporting, Google click context and
remote-controlled SKAdNetwork and AdAttributionKit conversion values
(Conversion Hub — edit the schema in the TrackHub UI, devices pick it up without an app release).

> **Full step-by-step integration walkthrough (where the call goes, SwiftUI vs UIKit,
> verification, troubleshooting):** see [`INTEGRATION.md`](INTEGRATION.md).

> **Build status.** GitHub Actions (`.github/workflows/ios-ci.yml`) builds the Swift package,
> runs the executable contract suite and compiles the library for a generic iOS Simulator on
> every push and pull request. The source below requires the `1.9.0` release tag to be published
> before consumer apps can resolve that version.

## Install

Xcode → File → Add Package Dependencies → `https://github.com/Alexander-kuksa/trackhub-sdk` →
Dependency Rule: Up to Next Major `1.9.0`. iOS 14+, no third-party dependencies.

Swift Package Manager (`Package.swift`):

```swift
.package(url: "https://github.com/Alexander-kuksa/trackhub-sdk", from: "1.9.0")
```

## Usage

```swift
import TrackHub
import ApphudSDK

Apphud.start(apiKey: "<Apphud key>")

TrackHub.setGoogleAdsConsent(
    adUserData: consent.adUserData,
    adPersonalization: consent.adPersonalization,
    eea: consent.isEea
)

// Mainland China only, after your PIPL consent UI resolves these values:
// TrackHub.setPIPLConsent(
//     piplConsent: consent.pipl,
//     crossBorderTransferConsent: consent.crossBorder,
//     adsMeasurementConsent: consent.adsMeasurement
// )

// On app launch (e.g. in AppDelegate / @main init), after Apphud starts.
// Copy the app values from TrackHub → SDK integration. AppBackend below is
// your authenticated API; it keeps the TrackHub S2S secret off the device.
TrackHub.configure(
    endpoint: URL(string: "https://postbacks.example.com")!, // your ingest domain
    ingestToken: "<app ingest token from the TrackHub app page>",
    userId: Apphud.userID(),         // same custom user id in both SDKs
    sdkSecret: "<app sdk secret>",   // ordinary signed measurement + purchase context
    attConsentWaitingInterval: 120,  // first install waits for ATT, hard cap 360s
    apphudDeviceIdentifiersHandler: { idfa, idfv in
        Apphud.setDeviceIdentifiers(idfa: idfa, idfv: idfv)
    },
    backendAttributionProvider: { userId, completion in
        AppBackend.fetchTrackHubAttribution(userId: userId, completion: completion)
    },
    backendPrivacyErasureHandler: { userId, reason, completion in
        AppBackend.eraseTrackHubUser(userId: userId, reason: reason, completion: completion)
    },
    apphudAttributionHandler: { data, completion in
        Apphud.setAttribution(
            data: ApphudAttributionData(rawData: data),
            from: .custom,
            identifer: nil,
            callback: { accepted, _ in completion(accepted) }
        )
    },
    attributionChangedHandler: { attribution in
        // Update app routing/UI when a delayed click or reattribution wins.
        print(attribution.network, attribution.campaignId ?? "organic")
    }
)

// Show this only after your contextual explanation / onboarding step.
// Requires NSUserTrackingUsageDescription in the host app's Info.plist.
TrackHub.requestAppTrackingTransparency()

// App sessions are tracked automatically after configure() (DAU/WAU/MAU + retention).

// Canonical sales funnel → TrackHub + Google (when the preset is enabled):
TrackHub.trackOnboardingShown()                  // when onboarding becomes visible
TrackHub.trackPaywallShown(at: .onboarding)      // when that paywall is presented
TrackHub.trackPurchaseCtaTapped(at: .onboarding) // before StoreKit; trial or purchase CTA

// Other custom engagement events:
TrackHub.trackEvent("tutorial_done", callbackParams: ["step": "3"])

// After a successful store purchase, send only the stable transaction identity.
// Apphud remains the source of truth for revenue/value/currency.
TrackHub.trackPurchaseObserved(
    transactionId: String(transaction.id),
    productId: transaction.productID
)
```

`AppBackend` must authenticate the signed-in user, call TrackHub's
`/sdk/attribution` or `/sdk/forget-device` endpoint with the linked S2S
connection's `X-TrackHub-Token`, and return the attribution response bytes or
erasure success. Never return that S2S token to the app. Without these backend
callbacks, attribution reads and `forgetDevice` fail closed; ordinary install,
session, event and conversion-value measurement continues.

Owned-media deferred paths currently use Google Play Install Referrer on
Android. iOS intentionally receives no probabilistic IP/UA fallback until a
deterministic App Store hand-off is available.

Apple Search Ads/AdServices collection is legacy and disabled by default. Do
not pass `enableLegacyAsaAttribution: true` unless the TrackHub backend has also
been explicitly re-enabled for legacy ASA processing.

### AdAttributionKit

SDK 1.8 updates SKAdNetwork and AdAttributionKit from the same conversion-value schema. Add the
`AttributionCopyEndpoint` Info.plist key using the origin shown on the app page in TrackHub. To
receive re-engagement copies, also enable
`EligibleForAdAttributionKitReengagementPostbackCopies`.

For a re-engagement universal link, capture Apple's conversion tag and apply subsequent events to
that exact conversion window:

```swift
let conversionTag = TrackHub.handleAdAttributionReengagement(url)
TrackHub.trackEvent(
    "offer_accepted",
    adAttributionTarget: .reengagement,
    conversionTag: conversionTag
)
```

iOS 17.4 supports base AdAttributionKit updates, iOS 18 adds install/re-engagement targeting, and
iOS 18.4 adds conversion tags. Older systems keep the SKAdNetwork fallback.

### iOS Google Ads attribution (gclid / gbraid)

When a Google Ads deep link carries `gclid` and/or `gbraid`, forward it to TrackHub. On a cold
launch call this **before** `configure(...)`; on an already-running app the SDK immediately forces
a new `session_start`. TrackHub caches the click server-side for downstream App Conversion events.
`wbraid` is retained for the separate web/offline conversion contour:

```swift
// In your URL handler — and, on a cold launch from a click, the launch URL:
TrackHub.handleDeepLink(url)            // pulls gclid / gbraid / wbraid
// …or set it directly if you obtained the id another way:
TrackHub.setGoogleClickId(gclid: "…", gbraid: "…")

TrackHub.configure(/* … */)             // call AFTER the click id is set
```

Pure SKAdNetwork installs carry no click id and stay SKAN-aggregate (Apple's privacy model).

### Optional: improved iOS measurement without Firebase

Base App Conversion delivery does not require Firebase or another Google SDK. For Google's
optional Integrated Conversion Measurement on iOS (especially EEA/UK/Switzerland), add the
standalone `GoogleAdsOnDeviceConversion` package in the host app, fetch its opaque
`aggregateConversionInfo`, and pass it before TrackHub's first `configure` call:

```swift
import GoogleAdsOnDeviceConversion

ConversionManager.sharedInstance.setFirstLaunchTime(TrackHub.firstOpenAt)
ConversionManager.sharedInstance.fetchAggregateConversionInfo(for: .installation) { info, _ in
    TrackHub.configure(
        endpoint: URL(string: "https://postbacks.example.com")!,
        ingestToken: "<token>",
        sdkSecret: "<sdk secret>",
        userId: Apphud.userID(),
        googleOnDeviceMeasurementInfo: info
    )
}
```

TrackHub caches this opaque value and forwards it as `odm_info` on first-open and downstream
App Conversion requests. The standalone package is optional and is not Firebase.

### Optional: uninstall measurement

The host app keeps ownership of APNs registration. Forward the token from the normal AppDelegate
callback; TrackHub does not request notification permission or call
`registerForRemoteNotifications()` itself:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    TrackHub.setPushToken(deviceToken, environment: .production)
}
```

For a debug/sandbox APNs registration use `.sandbox`. The SDK persists the latest token, re-sends
it after `configure`, and signs the delivery with SDK Signature v2. Link an APNs connection to the
app in TrackHub before the daily silent uninstall probe can run. No user-visible notification is
sent.

What happens under the hood:

- **First launch:** one `POST /ingest/{token}/install` with the available platform attribution
  context and any `gclid` / `gbraid` / `wbraid` set beforehand. Repeat launches are no-ops (and a failed
  report retries next launch).
- **Every launch:** the active conversion value schema is fetched from
  `GET /ingest/{token}/cv-schema` and cached locally.
- **`trackEvent(name, …)`:** sends the event to TrackHub analytics (`POST /ingest/{token}/sdk/track`,
  buffered offline with retry) and drives both on-device Apple attribution APIs via `track()`.
- **`track(event, revenueCents:)` (attribution only, no analytics):** the event is encoded via the schema
  (fine value 0–63 with linear revenue bucketing, SKAN 4 coarse value, optional window lock) and
  applied through the best available API:
  `updatePostbackConversionValue(_:coarseValue:lockWindow:)` on iOS 16.1+, fine-only on 15.4+,
  legacy `updateConversionValue` on 14.x. No-op when the event has no rule in the active schema.

## Notes

- Revenue/subscription source of truth is Apphud/S2S (webhooks + server notifications), not SDK
  events. `trackEvent` accepts engagement events only. `trackPurchaseObserved` sends no money: the
  server temporarily captures the device context required by Google and releases the conversion
  only after the matching Apphud transaction arrives. `track()` (without "Event") only drives
  Apple attribution conversion values on the device and sends no analytics.
- `trackPaywallShown` and `trackPurchaseCtaTapped` always use the stable event names `pw_shown`
  and `purchase_cta_tapped`. The standard placement is sent as the `placement_name` parameter,
  never appended to the event name. TrackHub supports parameters end-to-end.
- On iOS, configuration sends IDFV to Apphud immediately. After the explicit ATT request returns
  `authorized`, TrackHub sends IDFA to Apphud and uses it for Google App Conversion; denied,
  restricted and undetermined users keep the limited-tracking IDFV path.
- `attConsentWaitingInterval` mirrors Adjust's first-session ATT wait. It applies only before the
  first production install, buffers TrackHub install/session/events on disk, and releases them as
  soon as ATT resolves or the timeout expires. Apphud IDFV delivery and Apple SKAN/
  AdAttributionKit registration are never delayed. Values above 360 seconds are capped.
- When an SDK event is explicitly mapped to a Google standard engagement or custom event, its
  bounded primitive `callbackParams` become `app_event_data`; `partnerParams` are not forwarded
  there. SDK events can never use purchase semantics or SDK-authored revenue.
- Firebase is not required. Its optional `app_instance_id` bridge exists only for installations
  that deliberately keep GA4 forwarding alongside the App Conversion API.
- Google's standalone iOS On-Device Conversion Measurement package is optional. When used,
  pass its opaque info string before `configure`; TrackHub never interprets it.
- The SDK persists one `first_open_at` timestamp and sends ISO country/device context on every
  post-install report, so Google's required `fot`/`ctry_c` fields survive install/session races.
- For mainland-China traffic, call `setPIPLConsent` after your consent UI; denied or missing
  cross-border/ads-measurement consent then blocks Google delivery fail-closed.
- Legacy AdServices collection remains available only through the explicit
  `enableLegacyAsaAttribution` opt-in and is disabled by default.
- Set `debug: true` in `configure` to see `[TrackHub]` log lines.

## Development

Core logic (schema decoding + conversion value encoder) is platform-independent and covered by
a parity test suite that mirrors the backend tests:

```bash
swift run encoder-tests
```
