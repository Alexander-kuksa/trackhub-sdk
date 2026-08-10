# TrackHub iOS 3.0 integration reference

## Contract

SDK 3 is provider-neutral. `install_uid` is the private measurement identity for
one installation and is sent as `user_id`. It is regenerated after uninstall /
reinstall. TrackHub deliberately does not build an IDFV device graph.

External billing identities are optional provider-scoped links:

```swift
var config = TrackHubConfig(sdkKey: "<TRACKHUB_SDK_KEY>")
config.attConsentWaitingInterval = 120
TrackHub.start(config)
TrackHub.requestAppTrackingTransparency()

TrackHub.trackPaywallShown(at: .onboarding)
TrackHub.trackPurchaseCtaTapped(at: .onboarding)
// placement is encoded as the canonical placement_name parameter.
```

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

## First-party measurement geography (3.0.2)

The production `/install` acknowledgement includes `geo_ack_version: 1` on a
compatible server and may include ISO-3166 `country` and protective `eea`
fields resolved by Daively's trusted edge. The SDK validates them, scopes them
to the current `install_uid`, and durably caches them for later install,
session, event, consent and purchase-context payloads. The cache is a device
signal only: the server resolves trusted-edge geography again before consent or
external-delivery decisions.

`countryCode` remains an optional initial host fallback. A later server country
may replace it. EEA is monotonic-protective: host `true` OR cached `true` stays
true; cached false cannot narrow host true. No Locale, GPS or IP-based SDK
geolocation is performed, and no IP is persisted or added to a payload.

An app upgraded from 3.0.1 with an existing install credential schedules one
durable, idempotent `/install` context refresh when its server-geo cache is
missing. A `2xx` without `geo_ack_version: 1` is treated as an old server and
retried with backoff. The refresh retires after 12 retryable/old-contract
responses and fails silently. A v1 ACK with no `country` or `eea` is a valid
terminal answer: geography is genuinely unknown.

Release gate: publish/tag 3.0.2 only after the platform contract, tests and
production deployment are verified. The versioned ACK makes either rollout
order fail-safe, but server-first avoids unnecessary bounded retries.

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

1. Resolve TrackHub 3.x and confirm the dependency graph contains no Apphud or RevenueCat through TrackHub.
2. Start TrackHub with one SDK Key and link the chosen provider with one explicit call.
3. Run a clean Test Lab installation; verify install precedes the first session.
4. Verify foreground at 29:59 stays in-session and 30:01 starts a new session.
5. Exercise provider anonymous ID, login ID, logout, and restore without changing `install_uid`.
6. Complete an Apphud/RevenueCat sandbox purchase and verify the authenticated server event.
7. If Apple verification is enabled, verify the reconciliation seed confirms; otherwise verify lower-trust money remains visible.
8. Test offline queue, process restart, and exactly-once drain.
9. Test `gdprForgetMe` offline and after relaunch.
10. Confirm SDK Key, install credential and raw external identity are absent from logs/crash metadata.

## Upgrade from 2.x

This is an intentional clean break made before commercial integrations. Remove
any assumption that TrackHub starts after Apphud or reads it automatically. Add
the explicit `setExternalIdentity` line only when a provider link is wanted.
There is no dual 2.x/3.x server intake for native SDK reports.
