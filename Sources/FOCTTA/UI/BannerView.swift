// BannerView.swift — native SwiftUI consent banner (Week 3.1).
//
// PRIORITISED v1.0 SCOPE
// ──────────────────────
// This is the first user-visible surface of the iOS SDK. Customers
// (Motilal Oswal MF + Acme Financial Services on the prod side, plus
// the APEX demo tenant on staging) will judge the SDK on how this
// renders inside their iOS apps — so the implementation prioritises:
//
//   1. Correct behaviour over visual polish — Accept all / Reject all
//      wire through to `FOCTTA.consent.acceptAll/rejectAll`, the
//      verified Week 1+2 path that round-trips against staging.
//   2. Branding via WidgetConfig.colors so the same banner adapts to
//      every tenant's brand without an SDK release.
//   3. i18n via Localizable.strings so the 22 Indian languages
//      already scaffolded under `Resources/Localization/` are picked
//      up automatically by NSLocalizedString.
//
// WHAT'S DEFERRED (separate commits)
// ──────────────────────────────────
//   • Week 3.2 — DPDPA S.9 audience selector (Adult/Under-18) + minor
//     disclaimer strip + S.9(3) category force-off.
//   • Week 3.3 — Customize panel (per-purpose toggles + Save preferences).
//   • Week 3.4 — DigiLocker guardian handoff (Rule 10 parental consent).
//   • Snapshot tests via swift-snapshot-testing (added once UI shape
//     stabilises so we're not re-snapshotting every iteration).
//
// USAGE FROM SwiftUI CUSTOMER APP
// ───────────────────────────────
//   BannerView(
//       domain: "your-app.com",
//       visitorId: persistentVisitorId,
//       onDecision: { decision in
//           switch decision {
//           case .acceptAll, .rejectAll:
//               // SDK already recorded the decision via ConsentService.
//               dismissBanner()
//           case .customize:
//               // Week 3.3 — push the preference center view.
//               break
//           case .dismissed:
//               // User swiped away without choosing — banner stays
//               // mounted on next launch.
//               break
//           }
//       }
//   )
//
// USAGE FROM UIKit CUSTOMER APP
// ─────────────────────────────
//   let vc = BannerViewController(domain: "...", visitorId: id) { decision in ... }
//   present(vc, animated: true)

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI) && canImport(UIKit)

// MARK: - Theme

/// Theme resolved from the public `WidgetConfig.colors` dictionary.
/// Internal — customers don't customise this directly; they edit the
/// banner config in the FOCTTA dashboard and the SDK picks it up.
///
/// Each key is optional in the dashboard; missing keys fall through to
/// platform defaults so a tenant with no theme set still gets a usable
/// banner.
@available(iOS 15.0, *)
internal struct BannerTheme: Equatable {
    let primaryColor: Color
    let textColor: Color
    let buttonTextColor: Color
    let backgroundColor: Color
    let borderColor: Color

    /// Map the dashboard JSON `colors: { primaryColor, textColor, ... }`
    /// into SwiftUI colours. Hex parsing is best-effort: malformed values
    /// fall back to platform defaults rather than crashing the banner.
    static func from(_ config: WidgetConfig) -> BannerTheme {
        let c = config.colors ?? [:]
        return BannerTheme(
            primaryColor: hexColor(c["primaryColor"]) ?? Color.accentColor,
            textColor: hexColor(c["textColor"]) ?? Color.primary,
            buttonTextColor: hexColor(c["buttonTextColor"]) ?? Color.white,
            backgroundColor: hexColor(c["backgroundColor"]) ?? Color(uiColor: .systemBackground),
            borderColor: hexColor(c["borderColor"]) ?? Color(uiColor: .separator)
        )
    }

    /// Parse `#RRGGBB` or `#RRGGBBAA` into Color. Returns nil for any
    /// malformed input (caller falls back to platform default).
    static func hexColor(_ hex: String?) -> Color? {
        guard var s = hex, s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        }
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Constants

/// UserDefaults key for the persisted minor-mode flag. Namespaced so
/// host apps can introspect the value if they want to mirror the SDK's
/// audience state in their own analytics (purely additive; SDK is the
/// source of truth).
private let minorModeKey = "foctta.audience.isMinor"

// MARK: - Decision callback

/// The user's choice on the banner. Mirrored in Android as
/// `BannerDecision` — when adding a case here, add it on Android too
/// (the scripts/gen-sdk-types.ts drift check does NOT cover UI types,
/// so this is enforced by code review).
public enum BannerDecision: Equatable, Sendable {
    case acceptAll
    case rejectAll
    case customize
    /// The user dismissed without choosing — e.g. swipe-to-dismiss on iOS.
    /// SDK does NOT record consent in this case; host app should keep the
    /// banner mounted on next session start.
    case dismissed
}

// MARK: - BannerView

/// SwiftUI native consent banner.
///
/// - Parameters:
///   - domain: The domain key registered in the FOCTTA dashboard. Used
///     to fetch the right banner config (colours, copy, purpose list).
///   - visitorId: Opaque per-install identifier the host app generates
///     and persists. Same value the host app uses elsewhere via the
///     consent.check / record APIs.
///   - onDecision: Called when the user makes a choice. The SDK has
///     already recorded the decision against staging/prod via
///     ConsentService — your handler only decides what UI to show next.
@available(iOS 15.0, *)
public struct BannerView: View {
    private let domain: String
    private let visitorId: String
    private let onDecision: (BannerDecision) -> Void

    @State private var config: WidgetConfig?
    @State private var loadingError: String?
    @State private var inFlight: Bool = false

    /// DPDPA S.9 audience self-identification (Week 3.2).
    ///
    /// Persisted in UserDefaults under `foctta.audience.isMinor` so the
    /// choice survives app restarts — same UX contract as the web
    /// widget (`vc_minor_mode` in localStorage). When `true`,
    /// non-essential purposes are blocked from accept-all by S.9(3).
    ///
    /// Default `false` (adult) is the most permissive option; tenants
    /// who serve a child-directed site should set `behavior.childDirected`
    /// in the dashboard so the SDK can force this on at fetch time —
    /// that path lands alongside the operator-declared child-directed
    /// behaviour in a Week 3.2 follow-up.
    @State private var isMinor: Bool = UserDefaults.standard.bool(forKey: minorModeKey)

    public init(
        domain: String,
        visitorId: String,
        onDecision: @escaping (BannerDecision) -> Void
    ) {
        self.domain = domain
        self.visitorId = visitorId
        self.onDecision = onDecision
    }

    public var body: some View {
        Group {
            if let err = loadingError {
                errorState(err)
            } else if let cfg = config {
                banner(for: cfg)
            } else {
                loadingState
            }
        }
        .task {
            await loadConfig()
        }
    }

    // MARK: - States

    private var loadingState: some View {
        // Minimal loading shimmer — most banners load in < 200ms so a
        // full spinner overstates the wait. ProgressView is enough.
        VStack { ProgressView() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    private func errorState(_ message: String) -> some View {
        // Banner load failed (network unavailable, tenant misconfigured).
        // Customer apps should fall back to their own default messaging
        // — we just show a closable error so the banner doesn't trap
        // the user.
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("foctta_error_offline_will_retry"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button(action: { onDecision(.dismissed) }) {
                // foctta_button_close is sourced from the web's `back`
                // key and translated into all 23 languages by the
                // sync script. Previously hardcoded English here was
                // a Week 3.1 oversight, fixed in the i18n audit.
                Text(localized("foctta_button_close"))
            }
            .buttonStyle(.borderless)
            // Debug-only detail. Suppressed in release builds.
            #if DEBUG
            Text(message).font(.caption2).foregroundColor(.red)
            #endif
        }
        .padding(16)
    }

    private func banner(for cfg: WidgetConfig) -> some View {
        let theme = BannerTheme.from(cfg)
        // Operator-declared child-directed site (DPDPA S.9 — Rule 9
        // explanation 2). When set, the tenant has declared the entire
        // site / app is for children, so we FORCE minor mode + hide
        // the audience selector entirely. The user can't undo this
        // — that's the legal point. Mirrors the web cookie banner's
        // `childDirected` flag handling.
        let operatorChildDirected = (cfg.behavior?["childDirected"] ?? "").lowercased() == "true"
        let effectiveMinor = isMinor || operatorChildDirected
        return VStack(alignment: .leading, spacing: 12) {
            // DPDPA S.9 audience self-identification.
            //
            // Hidden when the operator has declared the site
            // child-directed — Rule 9 doesn't permit a "I'm an adult"
            // override on a child-directed property.
            if !operatorChildDirected {
                audienceSelector(theme: theme)
            }

            // S.9 disclaimer strip — visible whenever minor mode is
            // effective (user-selected OR operator-declared).
            if effectiveMinor {
                minorDisclaimer(theme: theme)
            }

            // Title — prefer the dashboard-configured title; fall back
            // to the localised default. NSLocalizedString picks the
            // right language for the user's device automatically.
            Text(cfg.content?["title"] ?? localized("foctta_banner_title"))
                .font(.headline)
                .foregroundColor(theme.textColor)

            // Body — same pattern.
            Text(cfg.content?["body"] ?? localized("foctta_banner_body"))
                .font(.subheadline)
                .foregroundColor(theme.textColor)
                .fixedSize(horizontal: false, vertical: true)

            // Action row. Customize sits on its own row above the two
            // primary actions; the primary "Accept all" is rightmost
            // (iOS convention).
            VStack(spacing: 8) {
                actionButton(
                    label: cfg.buttons?["customize"] ?? localized("foctta_button_customize"),
                    style: .secondary(theme),
                    action: { onDecision(.customize) }
                )
                HStack(spacing: 8) {
                    actionButton(
                        label: cfg.buttons?["rejectAll"] ?? localized("foctta_button_reject_all"),
                        style: .secondary(theme),
                        action: { Task { await record(action: .rejectAll) } }
                    )
                    actionButton(
                        label: cfg.buttons?["acceptAll"] ?? localized("foctta_button_accept_all"),
                        style: .primary(theme),
                        action: { Task { await record(action: .acceptAll) } }
                    )
                }
            }
            .disabled(inFlight)
        }
        .padding(16)
        .background(theme.backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.borderColor, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Audience selector (DPDPA S.9)

    /// Two-button segmented control. The Adult side is the default;
    /// switching to Minor turns on S.9 protections immediately, so the
    /// disclaimer strip + category filtering apply BEFORE any consent
    /// action is taken.
    private func audienceSelector(theme: BannerTheme) -> some View {
        let adult = localized("foctta_audience_adult")
        let minor = localized("foctta_audience_minor")
        return HStack(spacing: 0) {
            audienceButton(label: adult, selected: !isMinor, theme: theme) {
                setMinor(false)
            }
            audienceButton(label: minor, selected: isMinor, theme: theme) {
                setMinor(true)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(theme.primaryColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func audienceButton(
        label: String,
        selected: Bool,
        theme: BannerTheme,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .background(selected ? theme.primaryColor : Color.clear)
        .foregroundColor(selected ? theme.buttonTextColor : theme.primaryColor)
        // a11y: announce the selected state so VoiceOver says
        // "Adult (18+), selected button" / "Under 18 / Guardian,
        // button". Without this, VoiceOver users hear two identical
        // buttons and can't tell which is active.
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// DPDPA S.9 disclaimer strip. Inline (not a sheet/alert) so the
    /// restricted mode is visible at all times when minor — matches
    /// the web banner's `childStripHtml` pattern.
    private func minorDisclaimer(theme _: BannerTheme) -> some View {
        // Orange tint via opacity for a soft "warning" feel without
        // requiring a custom asset bundle. The shield emoji is part
        // of the source string (Localizable.strings has it baked in).
        Text(localized("foctta_minor_disclaimer"))
            .font(.caption2)
            .foregroundColor(Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // a11y: signal that this is an important live update so
            // VoiceOver announces the S.9 protection notice when it
            // appears (right after the user taps "Under 18 / Guardian").
            // Without this, VoiceOver users only hear the segmented
            // control change and miss the critical DPDPA disclosure.
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// Toggle minor mode + persist. We touch UserDefaults synchronously
    /// because the value is a single Bool and the write is far smaller
    /// than the cost of dispatching to a background queue.
    private func setMinor(_ value: Bool) {
        guard isMinor != value else { return }
        isMinor = value
        UserDefaults.standard.set(value, forKey: minorModeKey)
    }

    // MARK: - Actions

    /// Record the user's choice against the staging/prod backend, then
    /// surface the decision to the host app. ConsentService internally
    /// handles retry + offline-queue, so this `try` only throws when
    /// every retry has been exhausted AND the offline queue has
    /// accepted the work; the host can still dismiss the banner.
    ///
    /// DPDPA S.9(3) enforcement: when [isMinor] is true, accept-all
    /// records consent ONLY for categories whose `required == true`
    /// (essential / strictly-necessary). Reject-all is unchanged —
    /// the user is rejecting everything regardless of audience.
    private func record(action: BannerDecision) async {
        guard let cfg = config else { return }
        inFlight = true
        defer { inFlight = false }
        // S.9(3) — when minor (user-selected OR operator-declared
        // child-directed site), accept-all is restricted to required
        // categories. The reject-all path always tracks all categories
        // (the user explicitly rejected the lot).
        let operatorChildDirected =
            (cfg.behavior?["childDirected"] ?? "").lowercased() == "true"
        let effectiveMinor = isMinor || operatorChildDirected
        let categoriesForAccept = effectiveMinor
            ? cfg.categories.filter { $0.required }.map(\.id)
            : cfg.categories.map(\.id)
        let categoriesForReject = cfg.categories.map(\.id)
        do {
            switch action {
            case .acceptAll:
                _ = try await FOCTTA.consent.acceptAll(
                    domain: domain,
                    visitorId: visitorId,
                    availableCategories: categoriesForAccept,
                    regulation: cfg.regulation ?? .dpdpa
                )
                onDecision(.acceptAll)
            case .rejectAll:
                _ = try await FOCTTA.consent.rejectAll(
                    domain: domain,
                    visitorId: visitorId,
                    availableCategories: categoriesForReject,
                    regulation: cfg.regulation ?? .dpdpa
                )
                onDecision(.rejectAll)
            default:
                break
            }
        } catch {
            // ConsentService enqueues to the offline queue on
            // retries-exhausted, so the user's tap is durable. We still
            // surface the decision so the host can dismiss the banner;
            // sync happens transparently when the network returns.
            onDecision(action)
        }
    }

    // MARK: - Helpers

    private func loadConfig() async {
        do {
            config = try await FOCTTA.config.get(domain: domain)
        } catch {
            loadingError = "\(error)"
        }
    }

    /// All 23 languages are bundled in `.lproj` resources at build time
    /// by `scripts/sync-sdk-translations.ts` (which reads
    /// `packages/sdk/src/banner/translations.ts` — the single source of
    /// truth shared with the web banner). There is no runtime translation
    /// step: NSLocalizedString resolves directly against the SDK bundle.
    private func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}

// MARK: - Button style

@available(iOS 15.0, *)
private enum ActionStyle {
    case primary(BannerTheme)
    case secondary(BannerTheme)
}

@available(iOS 15.0, *)
private func actionButton(
    label: String,
    style: ActionStyle,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Text(label)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
    }
    .background(
        Group {
            switch style {
            case .primary(let t): t.primaryColor
            case .secondary(let t): Color.clear.overlay(
                RoundedRectangle(cornerRadius: 8).stroke(t.primaryColor, lineWidth: 1)
            )
            }
        }
    )
    .foregroundColor(
        {
            switch style {
            case .primary(let t): t.buttonTextColor
            case .secondary(let t): t.primaryColor
            }
        }()
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
}

// MARK: - UIKit wrapper

/// Wrap [BannerView] for UIKit hosting apps. Present or push this
/// `UIViewController`; the SDK auto-dismisses it on user decision
/// (except for `.customize`, which keeps the banner mounted so the
/// host can push the preference center).
@available(iOS 15.0, *)
public final class BannerViewController: UIHostingController<BannerView> {
    public init(
        domain: String,
        visitorId: String,
        onDecision: @escaping (BannerDecision) -> Void = { _ in }
    ) {
        // Two-phase init: build the view with a no-op handler so super
        // is satisfied, then rebind to a handler that ALSO dismisses
        // the VC. Avoids a `[weak self]` race on the host's handler.
        super.init(
            rootView: BannerView(
                domain: domain,
                visitorId: visitorId,
                onDecision: { _ in }
            )
        )
        self.rootView = BannerView(domain: domain, visitorId: visitorId) { [weak self] decision in
            onDecision(decision)
            // .customize is the only decision that should keep the
            // banner mounted — host pushes the preference center.
            if decision != .customize {
                self?.dismiss(animated: true)
            }
        }
    }

    @MainActor required dynamic init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported — use init(domain:visitorId:onDecision:)")
    }
}

#endif
