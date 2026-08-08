# TrackHub iOS 2.0 integration reference

## Public startup surface

```swift
public struct TrackHubConfig {
    public let sdkKey: String
    public let environment: TrackHubEnvironment
    public var debugLogging: Bool
    public var countryCode: String?
    public var attConsentWaitingInterval: TimeInterval
    public var googleAdsConsent: TrackHubGoogleAdsConsent
    public var piplConsent: TrackHubPIPLConsent
    public var firebaseAppInstanceId: String?
    public var googleOnDeviceMeasurementInfo: String?
    public var attributionChangedHandler: TrackHubAttributionChangedHandler?
    public var deferredDeepLinkHandler: TrackHubDeferredDeepLinkHandler?
}
```

Standard production integration needs only `sdkKey`; all other fields are
explicit product/privacy choices. The removed 1.x `configure(...)`, manual
`userId`, Apphud adapters and backend providers have no 2.0 aliases.

## Recommended application flow

```swift
import ApphudSDK
import TrackHub

func applicationDidStart() {
    Apphud.start(apiKey: apphudKey)

    var trackHub = TrackHubConfig(sdkKey: trackHubSdkKey)
    trackHub.googleAdsConsent = googleConsent
    trackHub.piplConsent = piplConsent
    trackHub.countryCode = trustedCountryFallback
    trackHub.attributionChangedHandler = { snapshot in
        // Optional: update host UI. Apphud delivery already happened.
    }
    TrackHub.start(trackHub)
}
```

`TrackHub.start` is `@MainActor`: call it from the normal application-launch
callback, as above. It captures Apphud's current ID before returning, while all
disk and network work continues on TrackHub's private queues.

Call Apphud first. If Apphud registration finishes later, TrackHub observes the
new user ID on foreground/event and sends a signed identity update. A restore or
login therefore changes the binding without creating a second installation.

## Public methods

| Method | Purpose |
|---|---|
| `start(_:)` | Start SDK state and automatic lifecycle measurement |
| `trackEvent` | Non-financial custom/engagement event |
| `trackOnboardingShown` | Canonical onboarding impression |
| `trackPaywallShown(at:)` | Canonical paywall impression with placement |
| `trackPurchaseCtaTapped(at:)` | Canonical CTA tap with placement |
| `trackPurchaseObserved` | Short-lived StoreKit transaction/device context; no money |
| `trackVerifiedPurchase(_:)` | Durable Apple-signed purchase verification from native StoreKit verification or Apphud `transactionV2` |
| `handleDeepLink` | Capture bounded ad references, leave routing to host |
| `setGoogleClickIds` | Explicit Google reference handoff for wrappers |
| `setPushToken` | Forward APNs token; TrackHub never requests permission |
| `attribution` | Read durable device-scoped attribution snapshot |
| `resolveDeferredDeepLink` | Reserved API; returns `nil` on iOS until a deterministic handoff exists |
| `requestAppTrackingTransparency` | Host-triggered ATT prompt |
| `updateGoogleAdsConsent` | Change Google consent after startup |
| `updatePIPLConsent` | Change PIPL consent after startup |
| `updateCountryCode` | Change explicit country fallback |
| `gdprForgetMe` | Immediate local stop plus durable device erasure |

The typed paywall/CTA helpers always send the canonical placement in the
`placement_name` parameter. Do not create event-name suffixes per screen.

## Queue and delivery contract

Every measurement report is serialized and written before its network request.
The queue lives in `Application Support/TrackHub`, is excluded from backup and
uses atomic replacement. The SDK migrates the former Caches queue once. Corrupt
files are moved to a `.corrupt-*` quarantine.

Limits:

- 1,000 queued items;
- 4 MiB queue;
- 64 KiB item;
- one delivery in flight;
- retry base 1 second, full jitter, 5-minute cap.

Transport failure, 408, 429 and 5xx retry. Other 4xx are terminal for the item.
A stale signature returns server time; the SDK validates a 2020–2100 timestamp,
keeps the item, re-signs with process-local offset and retries. It never changes
the device clock.

## Apphud ownership

TrackHub depends on ApphudSDK but never calls `Apphud.start`. It uses:

- `Apphud.userID()` for the current external identity;
- `Apphud.setDeviceIdentifiers` for consent-permitted device identifiers;
- `Apphud.setAttribution(... from: .custom ...)` for TrackHub attribution.

It never passes the TrackHub install credential to Apphud. Revenue is consumed
only from Apphud webhook/S2S on the TrackHub server.

## SKAN and AdAttributionKit

The SDK fetches the server conversion schema, applies monotonic fine/coarse/lock
updates and isolates install vs re-engagement windows. Signed responses may
carry a server-recalculated conversion instruction based on Apphud/S2S history.
Do not mirror server lifecycle events to force a conversion value.

For AdAttributionKit copies configure the documented `.well-known` endpoint and
Info.plist keys in the host application. These server-copy settings are separate
from `TrackHub.start`.

## Privacy durability

`gdprForgetMe` persists a small atomic job under Application Support before
network delivery, stops public tracking, clears all measurement identifiers and
retains only `install_uid` plus the private credential needed for erasure.
The privacy state is installation-scoped rather than SDK-Key-scoped, so it is
durable before `start` and cannot be reset by credential rotation.

Direct credential failure falls back to endpoint-bound HMAC recovery. One clock
correction is allowed per attempt; persistent auth failure backs off and remains
stopped. On server confirmation, the credential and `install_uid` are deleted
last and the durable local disabled state remains.

## Release verification

1. Build the app with iOS 15 deployment target.
2. Confirm exactly one ApphudSDK version is resolved.
3. Run a clean isolated Test Lab install.
4. Verify install precedes session in the timeline.
5. Trigger a paywall and custom event.
6. Complete an Apphud sandbox purchase. If key-only Apple purchase verification
   is enabled, also pass Apphud's `transactionV2` to
   `trackVerifiedPurchase(_:)`.
7. Turn network off, enqueue events, terminate, relaunch, restore network and
   verify the queue drains once.
8. Turn network off, call `gdprForgetMe`, terminate, relaunch online and verify
   erasure completes without any new session/event.
9. Confirm SDK Key and per-install token are absent from logs/crash reports.

## Upgrade from 1.x

This is a clean API break. Delete the old startup call and every host callback.
Replace all startup values with one SDK Key. Rename:

- `getAttribution` → `attribution`;
- `forgetDevice` → `gdprForgetMe`;
- consent/country setters → `update...` methods.

Do not keep two TrackHub startup paths in one binary.

### SKAN lock-window limitation

When Apple supplies no coarse conversion value, the SDK does not manufacture
`.low` merely to call the richer `updatePostbackConversionValue` overload.
Consequently `lockWindow` cannot be expressed on that absent-coarse path. This
is a deliberate fail-closed trade-off; AAK delivery remains unaffected.
