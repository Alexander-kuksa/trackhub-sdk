# TrackHub iOS SDK — Google Offline Conversions work package (SDK v1.3)

This is the **SDK-side slice** of the platform redesign plan
`trackhub/GADS_OFFLINE_CONVERSIONS_PLAN.md` (WP6 there). Read that file for the full
architecture; this one is self-contained enough to implement the iOS changes alone.

> Status note: an earlier revision of this file designed the backend pipeline from scratch.
> That was superseded after auditing the platform repo — the Apphud → Google conversion
> upload pipeline **already exists** there (`src/lib/gads-conversions.ts` +
> `src/lib/data-manager.ts`, Data Manager `events:ingest` transport, consent/PIPL gates,
> mapping UI at `/apps/[id]/google-ads`, queue + retries + diagnostics). What is missing on
> the SDK side is exactly the three features below.

## Why (one paragraph)

The platform matches a subscription event to a Google click via
`Install.gclid/gbraid/wbraid`, gated by the consent columns on `Install`. Today this SDK
delivers click ids **only in the one-shot install report** (`TrackHub.swift:212-213`), sends
**no consent signals** (the platform's Consent-Mode gates are dormant — no producer), and an
install reported under a generated `dev_*` id is never re-keyed after `setUserId`, so Apphud
events keyed by the real user id miss the install (`no_match`, conversion silently dropped).

## Changes (SDK v1.3)

### 1. Re-engagement click reporting — `sdk/click`

Current behavior: `setGoogleClickId` / `handleDeepLink` (`TrackHub.swift:86-101`) persist
gbraid/wbraid in UserDefaults; `reportInstallIfNeeded` attaches them once; a click captured
after the install was reported never reaches the backend.

New behavior:
- Store `captured_at` (ISO 8601, time of the deep link) alongside each stored click id.
- In `setGoogleClickId`: if the install was already sent (`installSentKey` is true) — or as
  soon as `configure` runs, for ids that arrived before it — send
  `POST /ingest/{token}/sdk/click` with body
  `{"user_id": ..., "gbraid"|"wbraid": ..., "captured_at": ...}` through the existing
  `send(path:body:)` so the offline buffer + fresh-timestamp HMAC signing apply unchanged.
- Last-click-wins locally: a new id overwrites the stored one and re-reports.

### 2. Consent API — Consent Mode v2 signals

The `Install` table already has `adUserData / adPersonalization / eea / attStatus`
(latest-wins on re-report); `installs.ts` already accepts the fields. Add the producer:

```swift
/// Consent Mode v2 signals from your CMP / onboarding. Call before configure()
/// when possible; safe to call again on change (server is latest-wins).
public static func setConsent(adUserData: Bool?, adPersonalization: Bool?, eea: Bool? = nil)
```

- Persist in UserDefaults; include as `ad_user_data` / `ad_personalization` / `eea` in the
  install body; on change after install, send `POST sdk/consent` with the same fields.
- Auto-capture ATT status (`ATTrackingManager.trackingAuthorizationStatus` → string) as
  `att_status` in the same bodies (no prompt is triggered — read-only).
- Without a shipped consent producer, EEA uploads run on the platform's "no signal → allow"
  legacy grace; with signals they become correct and DMA-compliant.

### 3. Identity alias — `sdk/alias`

In `setUserId` (`TrackHub.swift:75-77`): when the install was already reported under a
generated device id (`dev_*` from `resolveDeviceId`), send
`POST sdk/alias {"user_id": <new>, "previous_user_id": <dev_*>}` once, then update config.
The platform follows the alias when resolving the install for conversion matching.

## Non-changes (keep as-is)

`EventQueue` (offline buffer, re-signed at flush), HMAC signature scheme
(`<tsMillis>.<token>.<rawBody>`), SKAN encoder + `cv-schema` flow (it remains the App-campaign
iOS bid path — offline uploads do NOT optimize App campaigns; they optimize
Search / Performance Max / web-to-app), install one-shot semantics, session tracking.

## Tests

Extend the parity suite (`swift run encoder-tests`, no XCTest dependency):
- click storage: captured_at persisted; last-click-wins; pre-configure ids ride the install,
  post-install ids produce an `sdk/click` body (assert exact JSON keys);
- consent: body encoding matrix (nil / true / false), latest-wins re-send;
- alias: fires only for `dev_*` → real transitions, once.

## Android parity (separate repo, `trackhub-android`)

- Send `referrerClickTimestampSeconds` from the Play Install Referrer as
  `referrer_click_ts` in the install body (currently discarded — `TrackHub.kt:93`); the
  platform uses it as the click's `capturedAt`.
- Same `setConsent` API (CMP-driven; no ATT) and `sdk/click` on App-Link deep links carrying
  `gclid`/`gbraid`.
