# TrackHub iOS SDK — Integration Guide

> **Версия инструкции:** TrackHub iOS SDK `1.10.1`, iOS 14+, проверено 6 августа 2026 г.
> Контракты сервера: [`docs/SDK_CONTRACT.md`](../docs/SDK_CONTRACT.md); диагностика платформы:
> [`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md).

A complete, copy‑paste walkthrough for adding the TrackHub SDK to a **native iOS (Swift)**
app. Hand this to whoever owns the app's Xcode project. The integration keeps Apphud as the
financial source of truth while TrackHub owns attribution and product-event delivery.

> The exact values you need (`endpoint`, `ingestToken`, and `sdkSecret` if SDK Signature is on)
> are pre‑filled for your app in the TrackHub web UI:
> **app.daively.com → Apps → _your app_ → "SDK integration"**. Copy the snippet from there —
> this guide explains *where it goes* and *how to verify it*.

---

## What the SDK does (and does not do)

| Concern | Handled by |
| --- | --- |
| **Install reporting** (first launch) | This SDK → `POST /ingest/{token}/install` |
| **App sessions** (automatic) | This SDK → `POST /ingest/{token}/sdk/session` on every foreground (60s coalescing). Powers DAU/WAU/MAU + retention. **No code beyond `configure`.** |
| **Custom events** | `TrackHub.trackEvent("name")` → `POST /ingest/{token}/sdk/track`; shown in the app's **Engagement** tab + Raw Data |
| **User-level attribution / erasure** | Host app's authenticated backend → TrackHub with the linked S2S secret; the SDK receives only the response, never that secret |
| **App Conversion purchase bridge** | `TrackHub.trackPurchaseObserved(...)` sends transaction identity + short-lived device context; Apphud supplies authoritative value/currency |
| **Apple Search Ads attribution** | Dormant legacy contour; disabled by default in both SDK and backend |
| **SKAdNetwork conversion values** (remote‑controlled via Conversion Hub) | This SDK applies the schema on‑device; schema edits in the UI need **no app release** |
| **Revenue / trials / subscriptions / refunds** | **Apphud/S2S → TrackHub** is the permanent financial source of truth; the SDK never sends client-authored money |

So: this SDK makes **installs + sessions + custom events + SKAN/AdAttributionKit + Google device
context** work directly. User-level attribution and erasure additionally use the host app's
authenticated backend. Revenue flows through Apphud; Firebase is not required.

Google's separate `GoogleAdsOnDeviceConversion` iOS package is optional. It improves Integrated
Conversion Measurement in privacy-restricted iOS traffic, but is not needed for the base App
Conversion API path and is not Firebase.

---

## Prerequisites

- **iOS 14.0+** deployment target (the package requires it).
- The app already exists in TrackHub with **platform = iOS** (so it has an ingest token).
- **Apphud is already integrated** in the app (the SDK ties installs to `Apphud.userID()` so
  installs and revenue events join on the same user).
- For user-level attribution or `forgetDevice`, an app backend authenticates the user and calls
  TrackHub with a linked S2S connection. Its secret stays on that backend.
- A **real device** for release QA. AdAttributionKit/SKAN postbacks are not a
  simulator-level end-to-end attribution test.

---

## Step 1 — Add the Swift Package

**Xcode:** *File → Add Package Dependencies…* →
`https://github.com/Alexander-kuksa/trackhub-sdk` → Dependency Rule: **Up to Next Major** from
`1.10.1` → add the **`TrackHub`** library to your app target.

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/Alexander-kuksa/trackhub-sdk", from: "1.10.1")
// …and in the target's dependencies:
.product(name: "TrackHub", package: "trackhub-sdk")
```

No third‑party dependencies. `StoreKit` and `AdServices` are Apple system frameworks and are
linked automatically — **you do not add them manually**.

---

## Step 2 — Get your app‑specific values

From **app.daively.com → Apps → _your app_ → "SDK integration"**, copy:

- `endpoint` → `https://postbacks.daively.com`
- `ingestToken` → the app's token (shown in the snippet)
- `sdkSecret` → present **only if SDK Signature is enabled** for this app (recommended; it
  HMAC‑signs install reports so forged "organic" installs are rejected)

The web UI prints the snippet with these already filled in. Treat the `sdkSecret` like any
other secret in the repo (it ships inside the binary regardless — Signature raises the cost of
forgery, it is not a hard guarantee).

---

## Step 3 — Call `configure(…)` once at launch, **after Apphud starts**

Order matters: start Apphud first so `Apphud.userID()` returns the real id, then configure
TrackHub.

### SwiftUI (`@main App`)

If you have an `AppDelegate` adaptor, do it there (preferred). Otherwise, `App.init()`:

```swift
import SwiftUI
import TrackHub
import ApphudSDK

@main
struct AutoClickerApp: App {
    init() {
        Apphud.start(apiKey: "<your Apphud key>")   // must come first

        TrackHub.setGoogleAdsConsent(
            adUserData: consent.adUserData,
            adPersonalization: consent.adPersonalization,
            eea: consent.isEea
        )
        TrackHub.configure(
            endpoint: URL(string: "https://postbacks.daively.com")!,
            ingestToken: "<app ingest token>",
            userId: Apphud.userID(),
            sdkSecret: "<app sdk secret>",          // omit this line if Signature is off
            countryCode: measurementCountry,        // actual ISO country, not UI language
            attConsentWaitingInterval: 120,          // 0=off; maximum 360 seconds
            // debug: true,                          // uncomment while testing
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
            }
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

### UIKit (`AppDelegate`)

```swift
import UIKit
import TrackHub
import ApphudSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        Apphud.start(apiKey: "<your Apphud key>")   // must come first

        TrackHub.setGoogleAdsConsent(
            adUserData: consent.adUserData,
            adPersonalization: consent.adPersonalization,
            eea: consent.isEea
        )
        TrackHub.configure(
            endpoint: URL(string: "https://postbacks.daively.com")!,
            ingestToken: "<app ingest token>",
            userId: Apphud.userID(),
            sdkSecret: "<app sdk secret>",          // omit this line if Signature is off
            attConsentWaitingInterval: 120,          // 0=off; maximum 360 seconds
            // debug: true,
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
            }
        )
        return true
    }
}
```

`configure(…)` is safe to call every launch — it reports the install **only on first launch**.
The install is persisted before delivery and retries with bounded backoff in the current process and
across later launches until TrackHub acknowledges it. The Apple attribution conversion schema refreshes
each launch. All work is async on a background queue; it never blocks the main thread.

### Если TrackHub недоступен

- SDK сначала сохраняет отчёт, поэтому DNS/TLS error, timeout, HTTP `408`, `429` или `5xx`
  не теряет его и не ломает запуск приложения;
- один worker отправляет отчёты строго по очереди, с backoff+jitter до 5 минут;
- HTTP request ограничен 10 секундами, resource lifetime — 30 секундами, response — 64 KiB;
- очередь ограничена 1 000 элементами / 4 MiB, отдельный payload — 64 KiB;
- при переполнении раньше удаляется обычная аналитика, а неподтверждённый production install
  сохраняет приоритет;
- постоянный `4xx` не повторяется: исправьте endpoint, token, signature или payload и выпустите
  новую сборку;
- callback хост-приложения имеет watchdog 15 секунд. Всегда вызывайте `completion` ровно один раз,
  но даже забытый callback не должен навсегда заблокировать SDK.

SDK `1.10.1` безопасен при повторном `configure`: в одном namespace остаётся один
queue instance. До first unlock новые reports не дропаются: они временно буферизуются в memory
и атомарно сливаются с disk queue, когда protected storage становится доступным. One-shot click
refs очищаются только после durable enqueue session; UIKit device snapshot всегда снимается на
main thread, даже если host вызвал `configure` из background queue.

Это гарантия изоляции, а не гарантия бесконечного хранения. При длительной офлайн-работе сверх
лимитов самые старые второстепенные события могут быть вытеснены. Следите за Data Health и
проводите отдельный canary после восстановления сервера.

The Apphud handlers use the current official `setDeviceIdentifiers` and `setAttribution` APIs
that Apphud documents for MMPs such as Adjust. `AppBackend` authenticates the signed-in user,
calls TrackHub `/sdk/attribution` with the linked S2S connection's
`X-TrackHub-Token`, and passes the raw JSON response bytes to `completion`.
TrackHub then calls the Apphud handler on the main queue. The SDK persists the returned touchpoint
revision only when Apphud's callback returns `true`; network/Apphud failures
retry after a later install/session success or `refreshApphudAttribution()`.
Never embed or return the S2S token to the app. The app-wide `sdkSecret` cannot
authorize attribution reads or privacy erasure because it ships in the binary.

Configuration sends IDFV to Apphud immediately. Do not show ATT automatically at launch. After
your own contextual explanation (commonly near the end of onboarding), call:

```swift
TrackHub.requestAppTrackingTransparency { status in
    // optional: record or react to status; TrackHub/Apphud sync is automatic
}
```

When authorization succeeds, TrackHub reads IDFA, calls the Apphud device-identifiers handler
again with both IDFA and IDFV, and re-reports the latest ATT/device context to TrackHub. Denied,
restricted and not-determined users continue on the IDFV limited-tracking path.

With `attConsentWaitingInterval: 120`, the first production install/session and any early
TrackHub events stay in the SDK's disk-backed queue until ATT returns a final status or 120
seconds elapse. This is the Adjust-style waiting window: it affects only the first-ever install,
does not delay Apphud's initial IDFV call or Apple attribution registration, and is capped at 360
seconds. If iOS returns `notDetermined` because the app is inactive or another permission sheet is
open, the wait remains active so the app can retry the prompt; the timeout is always the fallback.

### Optional iOS ICM (still no Firebase)

For Google's improved Integrated Conversion Measurement, add the official standalone
`https://github.com/googleads/google-ads-on-device-conversion-ios-sdk` package to the host app.
Fetch its opaque info before the first TrackHub `configure` call:

```swift
import GoogleAdsOnDeviceConversion

ConversionManager.sharedInstance.setFirstLaunchTime(TrackHub.firstOpenAt)
ConversionManager.sharedInstance.fetchAggregateConversionInfo(for: .installation) { info, _ in
    TrackHub.configure(
        endpoint: URL(string: "https://postbacks.daively.com")!,
        ingestToken: "<app ingest token>",
        userId: Apphud.userID(),
        sdkSecret: "<app sdk secret>",
        googleOnDeviceMeasurementInfo: info
    )
}
```

Always call `configure` from the completion even when `info` is nil; base measurement continues
normally. TrackHub caches a non-empty value (maximum 4096 bytes) and forwards it only as Google's
documented `odm_info` parameter.

---

## Step 4 — Track the sales funnel and custom events

Sessions are automatic (Step 3). For the standard sales funnel, use the typed helpers:

```swift
TrackHub.trackOnboardingShown()                       // ob_shown
TrackHub.trackPaywallShown(at: .onboarding)           // pw_shown + placement_name
TrackHub.trackPurchaseCtaTapped(at: .onboarding)      // purchase_cta_tapped + placement_name
```

Call the helpers at the actual UI boundary, not after a later outcome:

| Helper | Exact trigger |
|---|---|
| `trackOnboardingShown()` | the onboarding becomes visible to the user |
| `trackPaywallShown(at:)` | that placement's paywall is actually presented |
| `trackPurchaseCtaTapped(at:)` | the purchase button is tapped, immediately before starting StoreKit; send this for both a trial CTA and a regular purchase CTA |

`purchase_cta_tapped` is intent, not revenue and not purchase success. A failed, cancelled or
abandoned StoreKit sheet therefore does not turn it into a paid conversion. If an abandonment
offer/paywall is then presented, report that new surface with `.transactionAbandonment`.

Available placements are `.onboarding`, `.inApp`, `.special`, `.settings`, `.onLaunch`,
`.quickAction`, and `.transactionAbandonment`. TrackHub supports parameters, so it always sends
the stable event names and puts the exact canonical value in `placement_name`; it never emits
`pw_shown_{placement}` or `purchase_cta_tapped_{placement}`.

For other funnel events, use **`trackEvent`** — it sends the
event to TrackHub analytics (the **Engagement** tab's event explorer) AND, when the name matches
a **Conversion Hub** rule, drives the on‑device SKAdNetwork conversion value:

```swift
TrackHub.trackEvent("level_complete")
TrackHub.trackEvent("tutorial_done", callbackParams: ["step": "3"])
```

`track(…)` (without "Event") still exists for **SKAN‑only** conversion values — it does not send
analytics. Prefer `trackEvent` for everything new. Events are persisted before delivery and drain one
at a time with bounded backoff, including across later launches, so a flaky network never drops them.

Revenue/subscription tracking does **not** go through SDK events — Apphud/S2S webhooks are the
source of truth. Current SDKs expose no revenue parameter on `trackEvent`.

## Step 5 — Bridge a confirmed purchase to App Conversion

After a successful store/Apphud purchase callback, pass the stable store transaction identity:

```swift
TrackHub.trackPurchaseObserved(
    transactionId: String(transaction.id),
    productId: transaction.productID
)
// StoreKit 2 convenience: TrackHub.trackPurchaseObserved(transaction)
```

The report contains no amount. TrackHub captures the real device context, encrypts it, waits for
the matching Apphud webhook, uses Apphud value/currency, and deletes the standalone context after
the join or a 72-hour TTL. `sdkSecret` is mandatory for this endpoint.

---

## Permissions / Info.plist

- Add **Privacy - Tracking Usage Description** (`NSUserTrackingUsageDescription`) with the
  product-approved explanation shown in Apple's ATT alert. Without it TrackHub fails closed and
  does not request permission.
- The SDK never prompts from `configure`; the host app chooses the contextual moment and calls
  `requestAppTrackingTransparency` explicitly.
- Update App Store Connect App Privacy answers for Device ID, product interaction, purchases and
  advertising attribution. The package privacy manifest declares the TrackHub side; the host app
  remains responsible for its combined TrackHub + Apphud + ad-network behavior.
- App Transport Security is satisfied (`https://postbacks.daively.com`); the SDK refuses any
  non‑HTTPS endpoint except `localhost`.

---

## Step 6 — Verify it works

For the authoritative workflow, open **TrackHub → app → Setup → Integration Test Lab**,
start an isolated run and pass its short-lived token only in the QA build:

```swift
TrackHub.configure(
    endpoint: URL(string: "https://postbacks.daively.com")!,
    ingestToken: "<app token>",
    userId: Apphud.userID(),
    sdkSecret: "<SDK secret>",
    countryCode: measurementCountry,
    debug: true,
    integrationTestToken: "<short-lived Test Lab run token>"
)
```

The shadow run is isolated from production analytics and never calls Google. After it passes,
remove the token from the build and use Test Lab's separately armed live canary to prove a real
Google response. Google has no App Conversion sandbox; a live canary may be counted.

1. Build and run on a **real device**; use TestFlight/App Store for the final attribution canary.
2. With `debug: true`, watch the Xcode console for `[TrackHub]` lines:
   - `install reported`
   - `schema vN active (… rules)`
   - on `track(…)`: `event … → fine …, coarse …, lock …`
3. In TrackHub, open **Apps → _your app_ → Setup → Integration Test Lab**. The timeline should
   show SDK report, signature, device IP, consent, first_open/session/custom event, purchase context,
   Apphud webhook and transaction join. Outside shadow mode, the normal detection badge should move
   to **detected** (and **Signed** if you passed `sdkSecret`), and the counters update:
   *First seen / Last seen / SDK installs / Signed*. The app's **Installs** KPI starts counting.

**Re‑testing the install on the same device:** the SDK remembers it already reported (a
`UserDefaults` flag). To force a fresh install report, **delete and reinstall** the app (or wipe
the app's data).

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `refusing non-HTTPS endpoint … — SDK not configured` in logs | `endpoint` isn't `https://`. Use `https://postbacks.daively.com`. |
| No `[TrackHub]` logs at all | `debug: true` not set, or `configure` not reached. Confirm it runs on launch. |
| `install reported` but app page still "not detected" | Detection reads the latest install; refresh the page. If Signature is **on** server‑side but you passed no `sdkSecret`, reports are rejected — pass the secret or disable Signature. |
| Badge shows **detected (unsigned)** | App built without `sdkSecret` while Signature is on. Add the secret and rebuild. |
| `attribution fetch requires backendAttributionProvider` | Supply a provider that calls your authenticated app backend. That backend calls TrackHub with a linked S2S token; never put the token in the app. |
| Legacy ASA attribution is absent | Expected by default. Re-enable both SDK `enableLegacyAsaAttribution` and backend `ENABLE_LEGACY_ASA_PROCESSING` only for an intentional rollback. |
| `track(…) before schema is available` | Called before the first schema fetch finished; harmless — the next launch caches the schema. Schema also persists across launches once fetched. |
| TrackHub server is offline | Expected behavior: the host app continues normally, and reports remain in the bounded queue. Restore the endpoint, foreground/relaunch the app and verify that the queue drains in Test Lab/Data Health. |
| Repeating `rejected with HTTP 4xx — not retried` | This is a permanent configuration/contract failure, not a transient outage. Check endpoint, ingest token, SDK secret/signature and server/SDK version compatibility. |

---

## Upgrade checklist

При обновлении существующего приложения до `1.10.1`:

1. Закрепите tag `1.10.1`, очистите Package Resolution только если Xcode всё ещё показывает
   старую версию, затем убедитесь, что в install payload виден `sdk_version=1.10.1`.
2. Не меняйте `ingestToken`, `sdkSecret` или Apphud `userId` без серверной ротации и плана миграции.
3. Добавьте backend callbacks для attribution/erasure; S2S secret никогда не переносите в приложение.
4. Проверьте ATT, Apphud identifiers, deep links, APNs token и purchase observation на реальном устройстве.
5. Пройдите shadow Test Lab, затем отдельно разрешённый live canary. Удалите test token из release build.

---

## How it behaves under the hood

- **First launch:** one `POST /ingest/{token}/install` carrying the Apphud `user_id`, app/OS
  version, and the `sdk_name`/`sdk_version` integration markers (inside
  the HMAC‑signed body when Signature is on). The report stays in the bounded disk queue and retries
  with backoff until acknowledged; repeat launches are no-ops after that acknowledgement.
- **Every launch:** `GET /ingest/{token}/cv-schema` refreshes and caches the active conversion
  schema, so Conversion Hub edits reach devices without an app release.
- **Apphud attribution:** the authenticated host backend calls
  `POST /ingest/{token}/sdk/attribution` with its S2S token and returns the selected touchpoint
  without raw click IDs. The SDK passes it to Apphud as provider `.custom` and
  suppresses a revision only after Apphud acknowledges it.
- **`track`:** encodes the event via the schema (fine 0–63 + SKAN 4 coarse + optional window
  lock) and applies it with the richest API the OS supports (iOS 16.1+ fine+coarse+lock, 15.4+
  fine‑only, 14.x legacy).

---

_SDK source & API: `Sources/TrackHub/TrackHub.swift`. Quick usage: `README.md`._
