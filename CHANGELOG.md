# Changelog

## 3.1.3 — 2026-09-08

Explicit Apple attribution ownership, without disabling Daively measurement.

- `TrackHubConfig.appleAttributionMode` defaults to `.active`, preserving
  registration and conversion-value management for existing integrations.
- Set `.passive` **before start** when AppsFlyer, Singular, Adjust or another
  implementation owns SKAdNetwork/AdAttributionKit. Daively then makes no
  Apple registration or conversion-value calls, including initial zero,
  cached/local schema, server responses, re-engagement and lock-window updates.
- Install, session, event, billing identity, purchase context, consent/privacy
  and optional Google ODM delivery remain enabled, subject to their existing
  privacy and reliability rules. No accepted first open is replayed.
- A main-actor permission boundary invalidates queued Apple work after a new
  configuration and checks before each native call. SKAN delivery does not
  wait for asynchronous AAK completion. Selecting
  passive is fail-closed for the process: a repeated default start cannot
  silently turn writes back on. This is not a live owner-switching protocol.
- Regression coverage includes native API spies, a suspended AAK/mode race,
  ODM bridge configuration and active/passive delivery against a local receiver.

Postback-copy routing and Google Ads Primary/Secondary actions are separate
settings. Passive does not automatically forward or import another MMP's
postbacks/claims. A host-app update is required to select this new mode;
keep exactly one Apple writer and validate the combined Release archive.

## 3.1.2 — 2026-09-08

Initial delivery signal consistency and ODM diagnostics. These changes require
a host-app update with SDK 3.1.2; existing 3.1.1 installations are unchanged.

- Events buffered during the initial ATT/ODM hold can receive the current
  permitted IDFA/IDFV and cached ODM immediately before their first dispatch.
  This applies to install, session, custom events and purchase context. It is
  installation-scoped and expires ten minutes after the original first open.
- Event timestamps, IDs, click references and economic fields remain unchanged.
  Explicit ATT denial at creation prevents later IDFA promotion. Consent
  withdrawal strips measurement signals; revoked ATT cannot retain old IDFA.
- Persist the final first-dispatch body before HTTP. Retries and restarts keep
  those exact bytes; late install refreshes cannot overwrite attempted reports.
  Legacy queues do not gain enrichment eligibility. Queue capacity remains
  bounded, with a privacy-safe fallback and no enrichment-driven eviction.
- The optional Google ODM bridge distinguishes available, empty, network error,
  provider error and unsupported results. The timeout remains five seconds by
  default, does not block the UI and does not discard a later valid callback.
- Bounded signed operational diagnostics contain only a random report UUID,
  SDK source/version, category and time. No ODM blob, advertising ID, install ID,
  user ID, error text or URL. They do not create Google conversions. The existing
  String? provider API remains compatible; typed providers take precedence.

Deployment order: server diagnostic allowlist/Health first, then a separately
versioned SDK release and host-app update. Verify on a real iPhone with ATT
allowed/denied, offline restart, late ODM, consent withdrawal and the host's
other SDKs before releasing the application. Package Release compilation alone
does not validate Google attribution or the host app's linker configuration.
