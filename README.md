# TrackHub iOS SDK 3.0

TrackHub measures app installations, 30-minute foreground sessions, engagement,
SKAdNetwork/AdAttributionKit values and short-lived purchase context. It has no
dependency on Apphud, RevenueCat or another billing SDK.

Current public release: `3.0.3`. Measurement geography is owned by Daively's
server and is not returned to or cached by the SDK.
Requirements: iOS 15+, Swift Package Manager, and a TrackHub SDK Key copied
from Daively → App → Setup. No application backend or login system is required.

## Install and start

Add `https://github.com/Alexander-kuksa/trackhub-sdk` in Xcode and select
`3.0.3` or a compatible `3.x` range.

```swift
import TrackHub

var config = TrackHubConfig(sdkKey: "<TRACKHUB_SDK_KEY>")
config.googleAdsConsent = currentGoogleConsent
config.countryCode = trustedCountryIfKnown
config.attConsentWaitingInterval = 120
TrackHub.start(config)
```

`start` is main-actor isolated. Disk and network work remains asynchronous. The
SDK Key is a credential: never log it or put it in URLs, analytics or crash data.

## Optional billing identity

TrackHub owns no billing imports. The host may link any provider after both SDKs
have started, and repeat the call after provider login/logout/restore:

```swift
// Apphud 3.x, 4.x, or a later compatible host API:
TrackHub.setExternalIdentity(provider: "apphud", userId: Apphud.userID())

// RevenueCat:
TrackHub.setExternalIdentity(provider: "revenuecat", userId: Purchases.shared.appUserID)

// Provider logout:
TrackHub.setExternalIdentity(provider: "apphud", userId: nil)
```

Supported namespaces are `apphud`, `revenuecat`, and `custom:<slug>`. Providers
are independent. Linking one never renames the TrackHub installation and never
clears another provider. TrackHub therefore works without a billing SDK and is
not tied to any Apphud version. The desired link is saved immediately; its
network delivery waits for the production install acknowledgement so it cannot
block the install behind a retrying identity request.

If the host wants attribution visible inside Apphud/RevenueCat, it should use
`TrackHub.attribution` and the billing provider's own public API. TrackHub does
not call another SDK on the application's behalf.

## Purchases and verification

Revenue, currency, trials, renewals and refunds come from authenticated
Apphud/S2S/store-server events, never from an app-authored event. Apple
verification is optional: Apphud-only or generic S2S money can count under its
lower trust source; attaching an In-App Purchase key lets Daively reconcile the
same transaction with Apple later.

For low-latency Google App Conversion matching, call after StoreKit success:

```swift
TrackHub.trackPurchaseObserved(transaction)
```

This queues transaction identity and short-lived device context, never price or
currency. It is protected from normal queue eviction. Family-shared Apple
access is retained for audit but excluded from revenue and paid conversion
forwarding.

## Events, links and consent

```swift
TrackHub.trackOnboardingShown()
TrackHub.trackPaywallShown(at: .onboarding)
TrackHub.trackPurchaseCtaTapped(at: .onboarding)
TrackHub.trackEvent("tutorial_done", callbackParams: ["step": "3"])
TrackHub.trackEvent("tutorial_done", deduplicationId: "tutorial-v1")
TrackHub.handleDeepLink(url)
TrackHub.requestAppTrackingTransparency()
```

Paywall placement is sent as the `placement_name` parameter. Do not encode it
in the event name. Do not mirror billing lifecycle or money as client events.
Use the optional `deduplicationId` only when the host may retry the same logical
event. It is trimmed, limited to 256 UTF-8 bytes, and scoped to the current
installation plus event name, so another device cannot suppress its event.
Without it, every call remains a distinct event. Server deduplication lasts for
the measurement-event retention window: 90 days by default, account-configured,
or indefinite when retention is `0`.

```swift
TrackHub.updateGoogleAdsConsent(newGoogleConsent)
TrackHub.updatePIPLConsent(newPiplConsent)
TrackHub.updateCountryCode("US")
```

Country is optional and must be actual measurement geography, not device
language. `countryCode` is only a host-provided fallback in the request. Daively
resolves current geography on every official SDK delivery from its trusted edge
or local country-only GeoIP database, then falls back to the host value and the
stored installation country. The response never returns `country` or `eea` to
the SDK. Version 3.0.3 also deletes the short-lived geography cache and refresh
job introduced in 3.0.2. TrackHub never uses Locale or GPS as geography and
never discovers, stores or sends an IP address. Both Google consent values stay
`unknown` in the no-CMP SDK configuration; the public consent API is optional.
Daively applies the approved app policy server-side: missing values default to
`GRANTED` globally, including confirmed EEA and unknown geography. An explicit
CMP denial always wins. Confirmed-EEA and unknown-geo grants are separately
observable and have operator kill switches. ATT is independent: denial removes
IDFA, while authorization only makes IDFA technically available and never
itself grants either Google signal. With missing EEA consent, the server policy
grant can nevertheless authorize Google delivery. The SDK shows no second
consent prompt.

## Privacy and failure behavior

`TrackHub.gdprForgetMe()` stops local measurement immediately, clears queued
measurement and persists a crash-safe device-erasure task. It still works while
the runtime safety circuit is open.

Before any report can use `install_uid`, iOS atomically writes it to a
backup-excluded protected file and mirrors it to `UserDefaults` for SDK 3.0.x
upgrade compatibility. A storage failure opens the process-local safety circuit
and no measurement is sent with a non-durable identity.

Reports are atomically stored before delivery. Transport failures, 408, 429 and
5xx retry with jitter; ordinary 4xx rejects only that report. The bounded queue
holds at most 1,000 reports / 4 MiB / 64 KiB per item. Install and transaction
context reports are protected from ordinary eviction.

Internal storage/codec/invariant failures open a process-local fail-silent
circuit until the next app launch. Network outages do not trip it. Swift traps,
Objective-C exceptions, OOM, stack overflow and binary/link failures cannot be
safely caught by an in-process SDK.

## Verification

```bash
swift build
swift test
swift run encoder-tests
```

See [INTEGRATION.md](INTEGRATION.md) for the contract and release checklist.
