# FOCTTA iOS SDK

Native consent management + DSAR + grievance + receipt audit for iOS apps. DPDPA / GDPR / CCPA out of the box.

> **Status:** v0.1.0 — wire layer complete, native UI scaffolded, awaiting v1.0 implementation phase. Not yet published. See `packages/sdk-ios/` in the FOCTTA monorepo.

## Auth model (v1.0)

The SDK uses the **same slug-routed public endpoints** the web cookie banner uses. **No API key is embedded in the app binary.** Authentication happens through:

- `tenantSlug` in the URL path for DSAR / rights endpoints
- `tenantId` (UUID) in the request body for consent endpoints
- Backend rate limits per tenant + IP hash

This is more secure than a public-key model (no key to extract from the binary) and architecturally consistent with the web widget.

## Install (when published)

Swift Package Manager — File → Add Package Dependencies in Xcode:

```
https://github.com/foctta/foctta-ios-sdk
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/foctta/foctta-ios-sdk.git", from: "1.0.0")
]
```

No CocoaPods support — CocoaPods trunk goes read-only Dec 2026. SPM only.

## Quick start

```swift
// AppDelegate.application(_:didFinishLaunchingWithOptions:)
do {
    try FOCTTA.configure(.init(
        tenantSlug: "motilal-oswal",
        tenantId: "00000000-0000-4000-9100-000000000001",
        environment: .production
    ))
} catch {
    print("FOCTTA configure failed: \(error)")
}
```

### Record consent (banner equivalent)

```swift
let result = try await FOCTTA.consent.acceptAll(
    domain: "your-app-domain.com",
    visitorId: persistentVisitorId,                       // generate once per install
    availableCategories: ["functional", "analytics", "marketing"],
    regulation: .dpdpa
)
print("Receipt: \(result.receipt.receiptId)")
```

Or with finer control:

```swift
let result = try await FOCTTA.consent.record(
    domain: "your-app-domain.com",
    visitorId: persistentVisitorId,
    action: .custom,
    categoriesAccepted: ["functional", "analytics"],
    categoriesRejected: ["marketing"],
    regulation: .dpdpa
)
```

### Check before firing third-party SDKs

```swift
let check = try await FOCTTA.consent.check(
    domain: "your-app-domain.com",
    visitorId: persistentVisitorId,
    purpose: "analytics"
)
if check.hasConsent {
    Analytics.shared.initialize()
}
```

### Reject all (withdraw equivalent)

```swift
try await FOCTTA.consent.rejectAll(
    domain: "your-app-domain.com",
    visitorId: persistentVisitorId,
    availableCategories: ["functional", "analytics", "marketing"]
)
```

The SDK in v1.0 implements withdrawal as recording a new consent-log with `reject_all` — most recent log wins. The full multi-step withdraw-all flow with OTP entry lands in v1.1.

### File a DSAR from inside the app

```swift
let dsar = try await FOCTTA.rights.fileDSAR(
    requestType: .access,
    identifiers: ["mobile": "+919999999999", "pan": "ABCDE1234F"],
    contactEmail: "user@example.com"
)
print("DSAR ref: \(dsar.dsar.referenceNumber)")
```

### ATT + consent in one step

```swift
if #available(iOS 14.5, *) {
    let result = try await FOCTTA.iOS.requestATTAndRecordConsent(
        domain: "your-app-domain.com",
        visitorId: persistentVisitorId
    )
    switch result {
    case .recorded(let att, let receipt):
        if case .authorized(let idfa) = att {
            // Pass idfa to AppsFlyer / Branch / etc.
        }
    case .denied, .restricted, .unsupported:
        // No tracking — initialize with no-IDFA paths.
        break
    }
}
```

### Receipt history (with cryptographic chain validation)

```swift
let receipts = FOCTTA.audit.history()

// Validate chain — detects local-cache tampering or multi-device gaps.
let result = FOCTTA.audit.validateChain()
if !result.intact {
    print("Chain breaks: \(result.breaks)")
}
```

## Architecture

- `FOCTTA` — facade. Configure once.
- `FOCTTA/Services/*` — `ConsentService`, `RightsService`, `AuditService`, `ConfigService`.
- `FOCTTA/Network/APIClient` — URLSession + async/await. No Alamofire. Retry 1s/2s/4s.
- `FOCTTA/Storage/*` — Idempotency / receipts / offline queue as atomic JSON files in Application Support.
- `FOCTTA/Platform/ATTHelper` — App Tracking Transparency bridge. Does NOT auto-prompt; customer decides timing.
- `FOCTTA/UI/BannerView` — SwiftUI banner. UIKit apps use `BannerViewController` (UIHostingController wrapper).

## Endpoints used

The SDK hits these public endpoints:

| Method | Path                                                  | Purpose                                        |
| ------ | ----------------------------------------------------- | ---------------------------------------------- |
| `POST` | `/v1/cookie-consent-logs`                             | Record a banner consent decision               |
| `POST` | `/v1/cookie-consent-logs/check`                       | Check whether a visitor consented to a purpose |
| `GET`  | `/v1/cookie-banners/public/<tenantId>/<domain>`       | Fetch banner config                            |
| `POST` | `/v1/dsar-requests/public/<tenantSlug>`               | File DSAR / grievance                          |
| `GET`  | `/v1/dsar-requests/public/<tenantSlug>/widget-config` | Fetch Rights Portal config                     |
| `GET`  | `/v1/dsar-requests/public/<tenantSlug>/status`        | Check DSAR status by reference                 |

All public, no auth required. Backend rate-limits handle abuse.

## Privacy manifest

Ships with `PrivacyInfo.xcprivacy` at the SPM target root. Declares Required Reason API usage for UserDefaults (CA92.1), file timestamps (C617.1), and disk space (E174.1). `NSPrivacyTracking = false`. No data collection — the SDK receives a pseudonymous `visitorId` from the caller; the customer is the data controller.

## What's _not_ in the SDK

- No API key in the app binary (v1.0 design: slug-routed public endpoints).
- No raw PII storage (email / phone / PAN).
- No IP capture (backend hashes at intake).
- No auto-ATT-prompt timing. Caller decides.
- No SDK-level telemetry to FOCTTA servers.

## Compatibility

- iOS 15.0+. SwiftUI 3. Covers ≥95% of installed base in India.
- Xcode 15+.
- Swift 5.9+.

## Building

```bash
cd packages/sdk-ios
swift build
swift test
```

## License

Apache 2.0 (see LICENSE at repo root once we go public).
