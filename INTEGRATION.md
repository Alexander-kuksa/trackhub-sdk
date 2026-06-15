# TrackHub iOS SDK — Integration Guide

A complete, copy‑paste walkthrough for adding the TrackHub SDK to a **native iOS (Swift)**
app. Hand this to whoever owns the app's Xcode project. The whole integration is one package
plus ~5 lines of code.

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
| **Apple Search Ads attribution** (campaign / ad group / keyword) | This SDK sends the AdServices token; **TrackHub resolves it with Apple server‑side** |
| **SKAdNetwork conversion values** (remote‑controlled via Conversion Hub) | This SDK applies the schema on‑device; schema edits in the UI need **no app release** |
| **Revenue / trials / subscriptions / refunds** | Today: **Apphud webhooks → TrackHub**. (Full on‑device StoreKit revenue tracking is being added in a later SDK release — see `SDK_PARITY_PLAN.md`.) |

So: this SDK makes **installs + sessions + custom events + attribution + SKAN** work on its own.
Revenue currently flows through the Apphud connection; you need both for full ROAS today.

---

## Prerequisites

- **iOS 14.0+** deployment target (the package requires it).
- The app already exists in TrackHub with **platform = iOS** (so it has an ingest token).
- **Apphud is already integrated** in the app (the SDK ties installs to `Apphud.userID()` so
  installs and revenue events join on the same user).
- A **real device** for testing — AdServices attribution tokens do **not** resolve on the
  Simulator.

---

## Step 1 — Add the Swift Package

**Xcode:** *File → Add Package Dependencies…* →
`https://github.com/Alexander-kuksa/trackhub-sdk` → Dependency Rule: **Up to Next Major** from
`1.0.0` → add the **`TrackHub`** library to your app target.

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/Alexander-kuksa/trackhub-sdk", from: "1.0.0")
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

        TrackHub.configure(
            endpoint: URL(string: "https://postbacks.daively.com")!,
            ingestToken: "<app ingest token>",
            sdkSecret: "<app sdk secret>",          // omit this line if Signature is off
            userId: Apphud.userID()
            // , debug: true                         // uncomment while testing
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

        TrackHub.configure(
            endpoint: URL(string: "https://postbacks.daively.com")!,
            ingestToken: "<app ingest token>",
            sdkSecret: "<app sdk secret>",          // omit this line if Signature is off
            userId: Apphud.userID()
            // , debug: true
        )
        return true
    }
}
```

`configure(…)` is safe to call every launch — it reports the install **only on first launch**
(retries next launch if the network call fails), and refreshes the SKAN conversion schema each
launch. All work is async on a background queue; it never blocks the main thread.

---

## Step 4 — (Optional) Track custom events

Sessions are automatic (Step 3). For your own funnel events, use **`trackEvent`** — it sends the
event to TrackHub analytics (the **Engagement** tab's event explorer) AND, when the name matches
a **Conversion Hub** rule, drives the on‑device SKAdNetwork conversion value:

```swift
TrackHub.trackEvent("level_complete")
TrackHub.trackEvent("trial_started")
TrackHub.trackEvent("tutorial_done", callbackParams: ["step": "3"])
```

`track(…)` (without "Event") still exists for **SKAN‑only** conversion values — it does not send
analytics. Prefer `trackEvent` for everything new. Events buffer offline and retry on the next
launch, so a flaky network never drops them.

---

## Permissions / Info.plist

- **Nothing to add.** No `Info.plist` keys are required.
- **No App Tracking Transparency (ATT) prompt and no IDFA** — AdServices attribution and
  SKAdNetwork are privacy‑preserving and work without the tracking permission.
- App Transport Security is satisfied (`https://postbacks.daively.com`); the SDK refuses any
  non‑HTTPS endpoint except `localhost`.

---

## Step 5 — Verify it works

1. Build and run on a **real device** (TestFlight/App Store build is best for AdServices;
   development builds report the install, but the AdServices token resolves reliably only for
   App Store / TestFlight installs).
2. With `debug: true`, watch the Xcode console for `[TrackHub]` lines:
   - `install reported`
   - `schema vN active (… rules)`
   - on `track(…)`: `event … → fine …, coarse …, lock …`
3. In TrackHub, open **Apps → _your app_ → "SDK integration"**. The detection badge should move
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
| Attribution always organic | AdServices doesn't resolve on Simulator; test on a real device with an App Store / TestFlight build, and only ad‑driven installs carry a campaign. |
| `track(…) before schema is available` | Called before the first schema fetch finished; harmless — the next launch caches the schema. Schema also persists across launches once fetched. |

---

## How it behaves under the hood

- **First launch:** one `POST /ingest/{token}/install` carrying the AdServices token, the
  Apphud `user_id`, app/OS version, and the `sdk_name`/`sdk_version` integration markers (inside
  the HMAC‑signed body when Signature is on). Repeat launches are no‑ops; a failed report
  retries next launch.
- **Every launch:** `GET /ingest/{token}/cv-schema` refreshes and caches the active conversion
  schema, so Conversion Hub edits reach devices without an app release.
- **`track`:** encodes the event via the schema (fine 0–63 + SKAN 4 coarse + optional window
  lock) and applies it with the richest API the OS supports (iOS 16.1+ fine+coarse+lock, 15.4+
  fine‑only, 14.x legacy).

---

_SDK source & API: `Sources/TrackHub/TrackHub.swift`. Quick usage: `README.md`._
