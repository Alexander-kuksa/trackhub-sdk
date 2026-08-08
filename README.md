# TrackHub iOS SDK 2.0

TrackHub measures installs, sessions and engagement, applies SKAdNetwork /
AdAttributionKit conversion values, and automatically bridges attribution to
Apphud. Apphud remains authoritative for subscriptions and revenue.

## Requirements

- iOS 15+
- Swift Package Manager
- ApphudSDK 4.4.8 (included as a package dependency)
- a TrackHub SDK Key copied from TrackHub → App → Setup

No application backend or login system is required.

## Install

Add this package in Xcode:

```text
https://github.com/Alexander-kuksa/trackhub-sdk
```

Select version `2.0.2` or a compatible `2.x` range.

## Start

Start Apphud first, then TrackHub:

```swift
import ApphudSDK
import TrackHub

Apphud.start(apiKey: "<APPHUD_API_KEY>")

var config = TrackHubConfig(sdkKey: "<TRACKHUB_SDK_KEY>")
config.deliveryFailureHandler = { failure in
    // Surface a diagnostic and release an app build with the current SDK Key.
    print("TrackHub delivery configuration requires attention: \(failure)")
}
config.countryCode = "DE" // actual measurement country, not UI language
config.googleAdsConsent = TrackHubGoogleAdsConsent(
    adUserData: .granted,
    adPersonalization: .denied,
    isEea: true
)
config.attConsentWaitingInterval = 120
TrackHub.start(config)
```

`TrackHub.start` is main-actor isolated. The launch callback above already runs
on the main actor; storage and network delivery remain asynchronous.

The SDK Key is one versioned configuration value (`thcfg_v1_...`). Never put it
in logs, URLs, analytics properties or support screenshots.

TrackHub reads `Apphud.userID()` automatically. Do not build a user-ID adapter
or proxy these SDK operations through an app backend.

## Events

```swift
TrackHub.trackOnboardingShown()
TrackHub.trackPaywallShown(at: .onboarding)
TrackHub.trackPurchaseCtaTapped(at: .onboarding)
TrackHub.trackEvent("tutorial_done", callbackParams: ["step": "3"])
```

Send funnel events at the moment they happen. Paywall placement is always sent
as the canonical `placement_name` parameter, never appended to an event name.
Do not send price, currency,
trial conversion, renewal or refund as client events; Apphud/S2S owns those facts.

For an enabled Google App Conversion purchase mapping, add device-side context
after StoreKit success:

```swift
TrackHub.trackPurchaseObserved(transaction)
```

This sends no money. TrackHub joins the transaction to authoritative Apphud
value/currency on the server.

## Deep links

Forward cold and warm links; calling before `start` is supported:

```swift
TrackHub.handleDeepLink(url)
```

The SDK captures bounded Google/ChatGPT Ads references without taking ownership
of application navigation.

iOS has no deterministic equivalent of Android Install Referrer. Therefore
`resolveDeferredDeepLink` currently returns `nil` and must not be used for
onboarding routing. Ordinary universal links continue to work through
`handleDeepLink`.

## ATT and identifiers

TrackHub never displays ATT automatically:

```swift
TrackHub.requestAppTrackingTransparency()
```

Add `NSUserTrackingUsageDescription` and call only after a contextual
explanation. IDFA is used only after authorization. IDFV and the authorized IDFA
are synchronized to Apphud automatically.

The SDK Key contains separate measurement/privacy and tracking origins. Without
ATT authorization the SDK uses only the measurement origin; ATT-authorized
tracking traffic uses the domain declared in `NSPrivacyTrackingDomains`.

## Consent updates

```swift
TrackHub.updateGoogleAdsConsent(newGoogleConsent)
TrackHub.updatePIPLConsent(newPiplConsent)
TrackHub.updateCountryCode("US")
TrackHub.updateFirebaseAppInstanceId(firebaseId)
TrackHub.updateGoogleOnDeviceMeasurementInfo(odmInfo)
```

Unknown consent stays unknown and is not treated as granted.

## Attribution

The TrackHub → Apphud custom-attribution bridge is automatic. To read the same
snapshot for host UI:

```swift
TrackHub.attribution { attribution in
    print(attribution?.campaignId ?? "organic")
}
```

## Privacy

```swift
TrackHub.gdprForgetMe()
```

This immediately disables local tracking, clears queued measurement and writes
a crash-safe device-erasure task. Network failure does not re-enable tracking.
This is durable even when called before `TrackHub.start` and remains disabled
after SDK Key rotation. The task retries on launch/foreground until TrackHub confirms `2xx` or `410`;
the per-install credential and install ID are deleted last.

Erasure is installation-scoped. Account-wide erasure for a logged-in product is
a separate authenticated server operation, not a mobile SDK dependency.

## Test Lab

```swift
var config = TrackHubConfig(
    sdkKey: "<TRACKHUB_SDK_KEY>",
    environment: .testLab(token: "<RUN_TOKEN>")
)
config.debugLogging = true
TrackHub.start(config)
```

Test Lab has an isolated queue namespace and never drains production events.

## Failure behavior

- public calls never wait on TrackHub network I/O;
- reports are atomically stored under Application Support before delivery;
- corrupt/oversized queue files are quarantined instead of crashing the host;
- transport errors, 408, 429 and 5xx retry with full jitter capped at 5 minutes;
- ordinary 4xx rejects only the bad report and unblocks FIFO;
- clock-skew 401 applies one bounded process-local correction;
- queue limits: 1,000 reports, 4 MiB total, 64 KiB per report;
- install reports have eviction priority;
- no TrackHub token/secret is logged or persisted in the measurement queue.

## Building and checks

```bash
swift build
swift test
swift run encoder-tests
```

`live-check` accepts endpoint, ingest token, SDK secret and optional Test Lab
token for an intentional live smoke. Do not paste production credentials into
shell history on shared machines.

See [INTEGRATION.md](INTEGRATION.md) for the full API and release checklist.
