# Changelog

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
