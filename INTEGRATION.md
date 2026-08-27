# TrackHub iOS 3.1 integration reference

## Contract

SDK 3 is provider-neutral. `install_uid` is the private measurement identity for
one installation and is sent as `user_id`. It is regenerated after uninstall /
reinstall. TrackHub deliberately does not build an IDFV device graph.

Version 3.0.3 persists `install_uid` to an atomic, backup-excluded protected file
before it can enter a report; `UserDefaults` is only an upgrade-compatibility
mirror. A 3.0.0–3.0.3 value migrates even when the offline queue is empty, so an
ordinary SDK update cannot create a phantom installation. iCloud restore and a
same-device SDK update are not reliably distinguishable from that legacy mirror;
3.0.3 intentionally preserves the previous restore behavior rather than risking
a new identity on every update.

Version 3.0.6+ gives `firstOpenAt` the same crash-safe boundary. It migrates the
existing 3.0.0–3.0.5 `UserDefaults` value once, then uses an atomic,
backup-excluded protected file as the source of truth. A hard kill after the
first report can no longer regenerate Google's `fot`. If the timestamp cannot
be persisted, the process-local storage circuit stops measurement without
blocking or crashing the host application; the next launch retries.

## Google integrated conversion measurement (3.1.0+)

For iOS applications promoted by Google, select the `TrackHubGoogleODM` Swift
package product. It adds Google's official On-Device Measurement runtime as an
optional adapter while the provider-neutral `TrackHub` core stays independent:

```swift
import TrackHub
import TrackHubGoogleODM

var config = TrackHubConfig(sdkKey: "<DAIVELY_SDK_KEY>")
TrackHubGoogleODM.start(config)
```

The adapter uses TrackHub's durable `firstOpenAt`, calls Google's official
`ConversionManager`, and adds the returned opaque `odm_info` to the one-shot
first-open report. It waits at most five seconds. A timeout, nil result,
unsupported region, Google runtime error, or unavailable TrackHub server never
blocks application startup and never disables measurement: reports enter the
durable queue and delivery proceeds fail-silent.

The package accepts Google ODM 2.x–3.x so SwiftPM can resolve a release compatible
with Firebase or another analytics SDK already owned by the host application.
The resolved version must still follow Google's published Firebase compatibility
matrix. An application that deliberately manages Google ODM itself can select
the core `TrackHub` product and provide the existing callback before `start`:

```swift
import GoogleAdsOnDeviceConversion
import TrackHub

var config = TrackHubConfig(sdkKey: "<DAIVELY_SDK_KEY>")
config.googleOnDeviceMeasurementInfoProvider = { firstOpenAt, completion in
    ConversionManager.sharedInstance.setFirstLaunchTime(firstOpenAt)
    ConversionManager.sharedInstance.fetchAggregateConversionInfo(for: .installation) {
        info, error in
        completion(error == nil ? info : nil)
    }
}
TrackHub.start(config)
```

The custom provider runs on the main actor and must return immediately; invoke
the completion asynchronously. It is called only before an unsent first open,
only when no explicit or cached ODM value exists, and never after a persisted
privacy stop. The default wait is five seconds and is capped at fifteen seconds
via `googleOnDeviceMeasurementTimeout`. Host callbacks are not wrapped.

SDK 3.0.5 also treats `wbraid` as durable one-shot re-engagement evidence on
existing installations. A `wbraid` captured by `setGoogleClickIds` or
`handleDeepLink` forces a normal numbered session and remains pending until the
session payload has entered the offline queue. This supports the server-side
web-to-app/Data Manager contour without replaying the one-shot install.

External billing identities are optional provider-scoped links:

```swift
import TrackHub
import TrackHubGoogleODM

var config = TrackHubConfig(sdkKey: "<DAIVELY_SDK_KEY>")
TrackHubGoogleODM.start(config)

// Present your own contextual explanation first, while the app is active.
TrackHub.requestAppTrackingTransparency()

TrackHub.trackPaywallShown(at: .onboarding)
TrackHub.trackPurchaseCtaTapped(at: .onboarding)
// placement is encoded as the canonical placement_name parameter.
```

`attConsentWaitingInterval` defaults to 120 seconds in 3.1.0. This delays only
outbound first-open delivery while ATT remains `.notDetermined`; it never blocks
the UI or public SDK calls. Events are written to the offline queue during the
wait. The deadline is anchored to the durable original `firstOpenAt`, so a hard
kill cannot restart another full 120-second wait. A resolved ATT result releases
delivery immediately. If the host never requests ATT, the timeout releases the
report without IDFA. Set the interval to `0` only when the app intentionally has
no ATT flow. A truthful `NSUserTrackingUsageDescription` must be present in the
host Info.plist; TrackHub intentionally never presents Apple's prompt by itself.

### Coexisting with Singular while Daively owns conversion values

For Daively-managed SKAN/AdAttributionKit conversion values, stop Singular from
writing the same Apple state. Singular may still run independent analytics and
its own Google ODM rail:

```swift
let singularConfig = SingularConfig(apiKey: "<SINGULAR_KEY>", andSecret: "<SINGULAR_SECRET>")
singularConfig.manualSkanConversionManagement = true
singularConfig.enableOdmWithTimeoutInterval = 5
Singular.start(singularConfig)
```

Use one SwiftPM-resolved `GoogleAdsOnDeviceConversion` version compatible with
the application's Firebase/Singular dependency graph. The manual-SKAN flag only
chooses who writes Apple's conversion values; it does not disable Singular event
reporting or ODM. Another application may choose another conversion-value owner,
but exactly one SDK must write those values.

```swift
TrackHub.setExternalIdentity(provider: "apphud", userId: Apphud.userID())
TrackHub.setExternalIdentity(provider: "revenuecat", userId: Purchases.shared.appUserID)
TrackHub.setExternalIdentity(provider: "custom:billing", userId: currentBillingID)
```

Call after provider initialization and again when its ID changes. `nil` logs out
only that provider. The call is non-blocking and durable. Before a production
install is acknowledged, the SDK persists the desired identity but defers its
network request; Test Lab remains independent. Version 3.0.1 also repairs a
persisted 3.0.0 queue by delivering a later install ahead of a blocked identity.
No Apphud or RevenueCat code is compiled into TrackHub.

## Server-owned measurement geography (3.0.3)

The SDK does not learn or cache the server's geography result. On every
official SDK request Daively resolves current geography from a trusted edge
country header or its local country-only GeoIP database. Only when those are
unavailable does the server use the optional host `countryCode`, followed by
the stored installation country for later reports. Manual S2S requests skip
request-IP GeoIP so a backend location cannot become the user's country.

No Locale, GPS or IP-based SDK geolocation is performed, and no IP is persisted
as geography or added to an SDK payload. Host EEA/consent signals remain normal
request inputs, but destination policy is enforced on the server. The install
response may contain the integer `geo_ack_version: 1` compatibility marker for
already-published 3.0.2 clients; it never contains `country` or `eea`, and 3.0.3
ignores it.

When upgrading from 3.0.2, the SDK deletes the retired install-scoped geography
cache and removes any queued `install_geo_refresh` report before delivery.

## Consent defaults (3.0.3)

`TrackHubGoogleAdsConsent()` defaults both signals to `.unknown`, and the public
consent API is optional for a basic integration. TrackHub never presents a
second Google consent UI. Daively fills missing signals with `GRANTED`
globally, including confirmed EEA and unknown geography. An explicit CMP value
always wins. Confirmed-EEA and unknown-geo grants are observable server-side
and have separate operator kill switches. ATT authorization only makes IDFA
technically available; it never changes either Google consent value. With
missing EEA consent, the independent server default supplies the effective
`ad_user_data` grant that can permit IDFA delivery.

## Public methods

| Method | Purpose |
|---|---|
| `start(_:)` | Start automatic install/session measurement |
| `setExternalIdentity(provider:userId:)` | Bind or clear an optional billing identity |
| `trackEvent` and typed sales helpers | Non-financial engagement events |
| `trackPurchaseObserved` | Transaction ID plus short-lived device context; no money |
| `handleDeepLink` / `setGoogleClickIds` | Capture bounded ad references |
| `setPushToken` | Forward a host-owned APNs token |
| `attribution` | Read the installation attribution snapshot |
| `requestAppTrackingTransparency` | Host-triggered ATT prompt |
| `updateGoogleAdsConsent` / `updatePIPLConsent` | Change consent after startup |
| `updateCountryCode` | Change a trusted country fallback |
| `gdprForgetMe` | Immediate stop plus durable installation erasure |

The SDK creates a new session after more than 30 minutes in background. A deep
link can force a re-engagement session immediately.

## Optional engagement-event deduplication

When application code can retry one logical event, pass a stable business key:

```swift
TrackHub.trackEvent("tutorial_done", deduplicationId: "tutorial-v1")
```

Blank values behave as absent; nonblank values over 256 UTF-8 bytes skip the
event. The SDK derives the wire ID as
`dedup1-` + lowercase SHA-256 of
`install_uid + NUL + event_name + NUL + trimmed_deduplication_id`. This makes
deduplication installation-scoped; the same key on another installation remains
a separate event. Calls without the parameter keep random IDs and are distinct.
The shared cross-platform fixture is:

```text
install_uid: 11111111-2222-4333-8444-555555555555
event_name: tutorial_done
deduplication_id: order-42
client_event_id: dedup1-9068017e11119b7a3c99163c1cb825e87ecda0542a4405cb526d506b941eb579
```

Deduplication lasts for the measurement-event retention window: 90 days by
default, configurable at account level, and indefinite when retention is `0`.

## Billing and attribution rules

- Apphud/S2S may be the economic source of truth without Apple credentials.
- Apple verification, ASSN and reconciliation are optional trust upgrades.
- Explicit `FAMILY_SHARED` access never books money, trials or paid conversions.
- Apphud payloads that omit ownership remain compatible and visible as
  `ownership unknown`, but do not create a permanent Apple family anchor.
- The acquisition transaction anchors all renewals in its transaction family.
  Current device activity never chooses the owner.
- A late purchase context repairs Daively attribution internally. A conversion
  already deduplicated by Google is not resent; Health reports this asymmetry.

Attribution back into a billing SDK is host-owned:

```swift
TrackHub.attribution { snapshot in
    // Optional: translate snapshot with the provider's documented API.
}
```

## Release checklist

1. Resolve TrackHub 3.1.0+ and confirm the dependency graph contains no Apphud or RevenueCat through TrackHub.
2. For Google-promoted iOS apps, select `TrackHubGoogleODM`, verify the resolved Google ODM/Firebase versions, and start through `TrackHubGoogleODM.start`.
3. Add a truthful `NSUserTrackingUsageDescription`; present the host explanation and call `requestAppTrackingTransparency` while the app is active.
4. If Singular coexists and Daively owns conversion values, set `manualSkanConversionManagement = true`; keep Singular ODM enabled when its external reporting is required.
5. Forward cold-start and subsequent deep/universal links to `TrackHub.handleDeepLink` before `start` when the host already has the URL.
6. Start with one SDK Key and link the chosen billing provider with one explicit `setExternalIdentity` call.
7. Run a clean Test Lab installation; verify install precedes the first session and the first-open trace records whether IDFA and/or ODM was present.
8. Verify foreground at 29:59 stays in-session and 30:01 starts a new session.
9. Exercise provider anonymous ID, login ID, logout, and restore without changing `install_uid`.
10. Complete an Apphud/RevenueCat sandbox purchase and verify the authenticated server event plus `trackPurchaseObserved` context.
11. If Apple verification is enabled, verify reconciliation confirms; otherwise verify lower-trust money remains visible.
12. Test offline queue, process restart during ATT/ODM wait, and exactly-once drain.
13. Test `gdprForgetMe` offline and after relaunch.
14. Confirm SDK Key, install credential and raw external identity are absent from logs/crash metadata.

## Upgrade from 2.x

This is an intentional clean break made before commercial integrations. Remove
any assumption that TrackHub starts after Apphud or reads it automatically. Add
the explicit `setExternalIdentity` line only when a provider link is wanted.
There is no dual 2.x/3.x server intake for native SDK reports.
