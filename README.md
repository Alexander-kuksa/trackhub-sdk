# Daively iOS SDK

The Daively SDK provides first-party mobile measurement for installations,
foreground sessions, product engagement, attribution links and Apple
conversion-value reporting. It does not depend on Apphud, RevenueCat or another
billing SDK.

Current release: `3.0.3` · Requirements: iOS 15+, Swift Package Manager

## Installation

Add the package in Xcode:

```text
https://github.com/Alexander-kuksa/trackhub-sdk
```

Select `3.0.3` or a compatible `3.x` version, then start the SDK with the key
from Daively → App → Setup:

```swift
import TrackHub

var config = TrackHubConfig(sdkKey: "<DAIVELY_SDK_KEY>")
config.googleAdsConsent = currentGoogleConsent
TrackHub.start(config)
```

The SDK key is a credential. Do not log it or include it in URLs, analytics or
crash reports. Startup, disk access and delivery are asynchronous and do not
need to gate the application's UI.

## Events and attribution

```swift
TrackHub.trackOnboardingShown()
TrackHub.trackPaywallShown(at: .onboarding)
TrackHub.trackPurchaseCtaTapped(at: .onboarding)
TrackHub.trackEvent("tutorial_done", callbackParams: ["step": "3"])
TrackHub.trackEvent("tutorial_done", deduplicationId: "tutorial-v1")
TrackHub.handleDeepLink(url)
```

Use `deduplicationId` only when the host may retry the same logical event.
Without it, every call represents a distinct event. Billing lifecycle and
revenue should come from an authenticated billing or store-server source, not
from custom client events.

After a successful StoreKit purchase, the optional purchase observation API
can provide short-lived matching context without sending price or currency:

```swift
TrackHub.trackPurchaseObserved(transaction)
```

## Optional billing identity

Daively is provider-neutral. The host application may associate an Apphud,
RevenueCat or custom identity without adding that provider as an SDK dependency:

```swift
TrackHub.setExternalIdentity(provider: "apphud", userId: Apphud.userID())
TrackHub.setExternalIdentity(provider: "revenuecat", userId: Purchases.shared.appUserID)
```

Repeat the call after provider login, logout or restore. Pass `nil` to clear an
identity. Daively does not call another billing SDK on the application's behalf.

## Privacy and consent

The package includes an Apple privacy manifest describing its collected data
categories and tracking use. The SDK reads IDFA only after ATT authorization;
when IDFA is unavailable it may attach IDFV as device context. Applications
that request ATT must provide an accurate purpose string and keep their App
Store privacy disclosures aligned with the destinations configured in Daively.

Consent is supplied by the host application's CMP or consent UI:

```swift
TrackHub.updateGoogleAdsConsent(currentGoogleConsent)
TrackHub.updatePIPLConsent(currentPiplConsent)
```

The SDK reports these signals to Daively and does not display its own consent
prompt or send events directly to Google. Advertising destinations and their
delivery policy are configured separately by the Daively operator. Do not
enable an advertising destination without the permissions and disclosures
required for the application's users and regions.

`countryCode` is an optional actual-country fallback, not a value inferred from
language or locale. The SDK does not use GPS and does not discover, store or
send an IP address.

```swift
TrackHub.updateCountryCode("US")
TrackHub.gdprForgetMe()
```

`gdprForgetMe()` stops local measurement, clears queued measurement and keeps
the erasure request retryable across relaunches.

## Reliability

Reports enter a bounded durable queue before delivery. Network failures retry
with backoff and do not block the host application. Internal storage, codec or
invariant failures open a process-local fail-silent circuit; privacy erasure
remains available.

See [INTEGRATION.md](INTEGRATION.md) for the complete API and release checks.
