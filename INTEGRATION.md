# FOCTTA Mobile SDK — Motilal Oswal Integration Walkthrough

> **For**: Motilal Oswal mobile engineering team integrating the FOCTTA SDK into 9 mobile apps (iOS + Android).
> **SDK version**: `v0.1.0-beta.2` (2026-05-28).
> **Status**: Production wire layer + dedicated-DB routing verified on 2026-05-28 (DSAR-2026-0001 issued from a curl smoke test against `app.foctta.com/v1/dsar-requests/public/motilal-oswal`).

---

## 1. What you're adding

The FOCTTA SDK gives your apps:

- **A consent banner** (DPDPA-compliant, branded with your colours)
- **A preference center** (per-purpose toggles)
- **An in-app rights portal** (data subjects can file DSARs without leaving your app)
- **A wire layer to FOCTTA's backend** (consent logs, DSAR requests, compliance receipts — all hash-chained for audit)

You don't need to build any of the UI or write any backend code. You add the SDK as a dependency, call `FOCTTA.configure(...)` at app launch with your tenant identifiers, and launch the SDK's views from your existing screens.

## 1.5. Fast path — Mobile SDK Quick Start in the dashboard

If you'd rather copy-paste pre-filled snippets than read the rest of this
walkthrough, log in to `app.foctta.com` and go to **Settings → Mobile SDK
Quick Start**. The Quick Start panel:

- Detects your tenant ID and slug automatically — you never type them.
- Lets you pick iOS, Android, or both and toggle on the surfaces you need
  (banner is mandatory; rights portal and preference center are optional).
- Generates pre-filled SwiftPM / Gradle dependencies, `configure(...)`
  snippets, and view-launch code for each surface — each block has its own
  Copy button.
- Has a **Send test consent log** button that hits the same wire endpoint
  a real device would, tagged with a recognisable test domain
  (`foctta-quickstart-test.<your-slug>`) so it's easy to filter out of
  your real analytics.

This document remains the authoritative reference for everything the
Quick Start doesn't cover (per-app domain conventions, identifier-set
governance, dedicated-DB routing notes, support escalation).

## 2. Your tenant identifiers

These were provisioned by FOCTTA support for your account:

| Field            | Value                                                                                 | Used for                                                       |
| ---------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `tenantSlug`     | `motilal-oswal`                                                                       | URL routing (slug-routed public endpoints)                     |
| `tenantId`       | _**Confidential — contact support@foctta.com to retrieve**_                           | Request body for consent log writes                            |
| `environment`    | `.production` (iOS) / `Environment.PRODUCTION` (Android)                              | Routes traffic to `https://app.foctta.com/v1`                  |
| `domain` per app | Each app's own domain — e.g. `app.motilaloswalmf.com`, `app.motilalosw-pms.com`, etc. | Distinguishes which app's surface the consent was collected on |

**On `tenantId`** — it's a UUID that appears in your dashboard URL once you're logged in (`app.foctta.com/_internal/tenants/<tenantId>`). It's not a secret per se (no auth attached) but we don't publish it via public endpoints. Embed it in your app's compiled binary alongside the slug.

## 3. Your tenant's identifier set (DPDPA Rule 14(5))

Per the widget-config the SDK fetches at runtime:

| Key            | Label                           | Required | Help text                                         |
| -------------- | ------------------------------- | -------- | ------------------------------------------------- |
| `emailAddress` | Email Address                   | Yes      | Customer email address                            |
| `phoneNumber`  | Phone Number                    | Yes      | Mobile or landline phone number                   |
| `cif`          | CIF (Customer Information File) | Yes      | Unique customer identifier in core banking system |

All three are required for a DSAR submission to be accepted. The SDK renders these fields dynamically once it fetches `RightsPortalWidgetConfig` — you don't need to hardcode them.

If you want to add/remove identifiers, update the per-tenant widget config via your FOCTTA dashboard at `app.foctta.com` → Rights → Widget Configuration. The SDK refreshes on next launch.

## 4. iOS integration — 4 files, ~30 lines

### 4.1 Add the SwiftPM dependency

In Xcode: **File → Add Package Dependencies** → paste:

```
https://github.com/san-techie21/foctta-ios-sdk.git
```

Pin to `Up to Next Minor Version → 0.1.0-beta.2`. Select the `FOCTTA` product.

Or in `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/san-techie21/foctta-ios-sdk.git", from: "0.1.0-beta.2"),
],
targets: [
  .target(name: "YourApp", dependencies: [
    .product(name: "FOCTTA", package: "foctta-ios-sdk"),
  ]),
]
```

### 4.2 Configure at app launch

In your `@main` App struct (or `AppDelegate.didFinishLaunching`):

```swift
import SwiftUI
import FOCTTA

@main
struct MotilalMutualFundApp: App {
    init() {
        do {
            try FOCTTA.configure(
                Configuration(
                    tenantSlug: "motilal-oswal",
                    tenantId: "<YOUR_TENANT_UUID>",
                    environment: .production
                )
            )
        } catch {
            // Telemetry — your existing logging stack
            print("[FOCTTA] configure failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
```

### 4.3 Show the consent banner on first launch

In whatever screen you currently show on cold-start (e.g. your splash / onboarding):

```swift
import FOCTTA

struct RootView: View {
    @State private var showingConsentBanner = !hasUserConsented()

    var body: some View {
        YourMainNavigationView()
            .sheet(isPresented: $showingConsentBanner) {
                BannerView(
                    domain: "app.motilaloswalmf.com",  // this app's domain
                    visitorId: persistentVisitorId(),   // your UUID, persisted in Keychain
                    onDecision: { decision in
                        showingConsentBanner = false
                        markConsentRecorded()
                    }
                )
            }
    }
}
```

`persistentVisitorId()` should generate a UUID once per install, persist it in Keychain, and return the same value forever. FOCTTA treats it as opaque — no PII required.

### 4.4 Show the Rights Portal in Settings

Add a "Privacy & Data Rights" row to your existing settings screen:

```swift
import FOCTTA

struct PrivacySettingsRow: View {
    @State private var showingRightsPortal = false
    @State private var widgetConfig: RightsPortalWidgetConfig?

    var body: some View {
        Button("Privacy & Data Rights") {
            Task {
                // Pre-fetch the tenant's config so the form renders
                // with the correct identifier fields immediately.
                widgetConfig = try? await FOCTTA.rights.getRightsPortalConfig()
                showingRightsPortal = true
            }
        }
        .sheet(isPresented: $showingRightsPortal) {
            RightsPortalView(
                domain: "app.motilaloswalmf.com",
                rightsPortalConfig: widgetConfig,
                prefilledEmail: signedInUserEmail(),
                onDone: { _ in showingRightsPortal = false }
            )
        }
    }
}
```

That's it. The SDK will:

1. Fetch your widget-config (renders fields for `emailAddress`, `phoneNumber`, `cif`)
2. Validate that all three are populated before enabling Submit
3. POST to `app.foctta.com/v1/dsar-requests/public/motilal-oswal`
4. Return a reference number like `DSAR-2026-0042` for your user to track

### 4.5 Required Info.plist entry (only if you use ATT)

If you call `FOCTTA.iOS.requestATTAndRecordConsent(...)`, add to your app's `Info.plist`:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>We use your advertising ID to deliver relevant offers. You can deny this permission and continue using the app normally.</string>
```

Apple **silently denies** the ATT prompt without this key. The exact copy is up to your marketing/legal team.

---

## 5. Android integration — 4 files, ~30 lines

### 5.1 Add the dependency

In your app's `build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.foctta:foctta:0.1.0-beta.2")
}
```

That's it. Maven Central is in your default `repositories` list (via `google()` / `mavenCentral()` in your `settings.gradle.kts`) — Gradle resolves the artifact automatically.

Published 2026-05-28, signed under the `com.foctta` namespace verified to FOCTTA Privacy Operations.

### 5.2 Configure at app launch

In your `Application` subclass:

```kotlin
import com.foctta.sdk.Configuration
import com.foctta.sdk.Environment
import com.foctta.sdk.FOCTTA

class MotilalMutualFundApp : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            FOCTTA.configure(
                context = this,
                tenantSlug = "motilal-oswal",
                tenantId = "<YOUR_TENANT_UUID>",
                environment = Environment.PRODUCTION,
            )
        } catch (e: Exception) {
            // Telemetry
            Log.e("FOCTTA", "configure failed", e)
        }
    }
}
```

Register the Application class in your `AndroidManifest.xml`:

```xml
<application
    android:name=".MotilalMutualFundApp"
    ...>
```

### 5.3 Show the consent banner on first launch

```kotlin
import com.foctta.sdk.ui.BannerActivity
import com.foctta.sdk.ui.BannerDecision

class SplashActivity : ComponentActivity() {
    private val bannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        when (BannerDecision.fromResultCode(result.resultCode)) {
            BannerDecision.AcceptAll, BannerDecision.RejectAll -> proceedToHome()
            BannerDecision.Customize -> launchPreferenceCenter()
            BannerDecision.Dismissed -> { /* keep showing on next session */ }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!hasUserConsented()) {
            bannerLauncher.launch(
                BannerActivity.newIntent(
                    context = this,
                    domain = "app.motilaloswalmf.com",
                    visitorId = persistentVisitorId(),
                ),
            )
        } else {
            proceedToHome()
        }
    }
}
```

### 5.4 Show the Rights Portal in Settings

```kotlin
import com.foctta.sdk.ui.RightsPortalActivity
import com.foctta.sdk.ui.RightsPortalDecision

class SettingsActivity : ComponentActivity() {
    private val rightsLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        when (RightsPortalDecision.fromResultCode(result.resultCode)) {
            RightsPortalDecision.Submitted -> {
                val ref = result.data?.getStringExtra(RightsPortalActivity.EXTRA_REFERENCE_NUMBER)
                showSnackbar("Privacy request submitted: $ref")
            }
            RightsPortalDecision.Cancelled -> { /* no-op */ }
        }
    }

    private fun openRightsPortal() {
        rightsLauncher.launch(
            RightsPortalActivity.newIntent(
                context = this,
                domain = "app.motilaloswalmf.com",
                prefilledEmail = signedInUserEmail(),
            ),
        )
    }
}
```

The Activity auto-fetches the widget-config on launch — no extra calls needed. If the fetch fails (offline, etc.), it falls back to the generic identifier form.

---

## 6. What to test per app, per platform

Run this checklist on at least one iOS device + one Android device per app before merging the SDK integration:

- [ ] **Cold start**: banner appears with Motilal Oswal branding (your `primaryColor` from the dashboard)
- [ ] **Accept all** → toast/log shows receipt ID like `CR-...`
- [ ] **Open Settings → Privacy & Data Rights** → form shows three fields: Email Address, Phone Number, CIF (all required)
- [ ] **Fill all three + submit** → toast shows reference like `DSAR-2026-NNNN`
- [ ] **Verify in FOCTTA dashboard**: log into `app.foctta.com` with your DPO credentials, navigate to **Rights → DSAR Requests**, confirm the row appears with the submitted reference number
- [ ] **Verify consent in dashboard**: navigate to **Consent Logs**, confirm the accept-all row appears with this app's domain
- [ ] **Reject all → reopen app** → banner does NOT re-appear (consent persisted via your `hasUserConsented()` logic)
- [ ] **Airplane mode → submit DSAR** → SDK queues the request offline; reconnect; verify it eventually lands in the dashboard

If any of these fail, the SDK's internal logging (enabled via `enableLogging: true` in Configuration) emits to `OSLog` (iOS) / Logcat with tag `FOCTTA` (Android).

---

## 7. What FOCTTA support handles for you

| You don't need to                 | We handle                                                      |
| --------------------------------- | -------------------------------------------------------------- |
| Build a banner UI                 | SDK ships the banner                                           |
| Build a DSAR form                 | SDK ships the form (dynamic to your config)                    |
| Set up a backend for consent logs | All consent logs land in your dedicated DB on `app.foctta.com` |
| Manage compliance receipts        | SDK + backend handle the hash chain                            |
| Configure 23 Indian languages     | Bundled in the SDK                                             |
| Wire DPDPA Rule 14 SLAs           | DSAR backend tracks 90-day SLA automatically                   |
| Operate the DPO dashboard         | Your DPO logs into `motilal-oswal.foctta.com`                  |

| You DO need to                            | Notes                                                           |
| ----------------------------------------- | --------------------------------------------------------------- |
| Generate a stable per-install `visitorId` | UUID, persisted in Keychain (iOS) / SharedPreferences (Android) |
| Decide WHERE to show the banner           | Typically splash / onboarding screen                            |
| Decide WHEN to require re-consent         | E.g. on policy version bump                                     |
| Add the Settings → Privacy row            | One Activity launcher / one SwiftUI row                         |
| Wire `enableLogging` for dev/staging only | Production should disable it                                    |

---

## 8. Support + escalation — file incidents in your FOCTTA dashboard

The FOCTTA platform has a built-in enterprise incident-tracking system. **File all SDK bugs through there** — emails / GitHub Issues are NOT the primary channel.

### How to file

1. Log into `https://motilal-oswal.foctta.com` with your DPO or IT Admin account
2. Settings → **Support** tab
3. Click **"+ New Incident"**
4. Fill in:
   - **Title** — short summary, e.g. "RightsPortalView crashes when phoneNumber field empty"
   - **Description** — repro steps, app version, SDK version (`0.1.0-beta.2`), device + OS
   - **Severity** (drives SLA — see table below)
   - **Category** — choose `integration_outage` for SDK bugs
5. Submit. You get a reference number `INC-2026-NNN` to track.

The incident lands in FOCTTA's platform support queue. Our team triages, responds, and closes through the same dashboard.

### SLA tiers (response / resolve)

| Severity | When to use                                                                             | Response        | Resolve          |
| -------- | --------------------------------------------------------------------------------------- | --------------- | ---------------- |
| **P1**   | Prod down for your end users (app crashes, DSARs blocked, consent log silently dropped) | 1 hour          | 4 hours          |
| **P2**   | Major degradation, workaround exists                                                    | 4 hours         | 1 business day   |
| **P3**   | Bug with low user impact, or UX issue                                                   | 1 business day  | 3 business days  |
| **P4**   | Feature request, minor copy issue, docs gap                                             | 3 business days | 10 business days |

P1 incidents auto-page our on-call via Slack + email — no need to also email separately.

### Quick reference

| Need                                  | Where                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------- |
| File a bug                            | Your dashboard → Settings → Support → New Incident                        |
| Track an incident                     | Same tab — incidents list shows status + SLA clock                        |
| Roadmap / feature requests            | File as `category=feature_request` severity P4                            |
| Documentation                         | `docs/product/` in the repo, plus this walkthrough                        |
| Emergency human escalation (P1 stuck) | Within an open P1 incident, click "Escalate" — pages our director on-call |

---

## 9. Roadmap visibility

These features are planned for the next SDK release (`v0.1.0-beta.3` or `v1.0` GA):

- **TestFlight distribution** for iOS sample app
- **Snapshot tests** in CI to catch visual regressions
- **DigiLocker mobile guardian flow** (DPDPA Rule 10 — parent-verifiable consent for minors)
- **Native-speaker review** for 3 Indian languages (Kashmiri, Bodo, Manipuri) currently using sibling-script fallbacks

Anything you'd add to this list? File a P4 `feature_request` incident in your dashboard → Settings → Support.
