// PreferenceCenterView.swift — native SwiftUI customise panel (Week 3.3).
//
// PURPOSE
// ───────
// Presented when the user taps "Customize" on `BannerView`. Lists
// every purpose from `WidgetConfig.categories` with a switch toggle,
// then writes a custom consent log via `FOCTTA.consent.record` on
// save. Mirrors the web cookie banner's customise panel in
// `packages/sdk/src/cookie-banner.ts`.
//
// BEHAVIOUR
// ─────────
//   • Essential (`required == true`) purposes are forced ON and the
//     toggle is disabled. "Required" badge sits next to the label.
//   • When DPDPA S.9 minor mode is active (`isMinor` parameter), all
//     non-essential purposes are forced OFF and disabled. A
//     localised "S.9 Blocked" badge replaces the toggle. Matches the
//     web banner's S.9(3) category-block pattern.
//   • Save → records the user's per-purpose selection as a single
//     `action: .custom` consent log via the verified ConsentService.
//   • Cancel → returns to the banner without writing anything.
//
// USAGE
// ─────
// `BannerView.onDecision(.customize)` should set host-app state that
// presents this view (sheet, navigation push, or fullScreenCover —
// the SDK is layout-agnostic). Once `onDone(.saved)` fires, the host
// dismisses both this view AND the underlying BannerView.

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI) && canImport(UIKit)

// MARK: - PreferenceCenterDecision

/// Outcome of the customise panel. The SDK ALREADY persists the
/// `.saved` decision before this callback fires; the host's job is
/// just to dismiss the appropriate views.
public enum PreferenceCenterDecision: Equatable, Sendable {
    /// User tapped Save. Consent was recorded as `action: .custom`
    /// with the per-purpose selection.
    case saved
    /// User tapped Cancel / Back. No consent recorded.
    case cancelled
}

// MARK: - PreferenceCenterView

/// Native SwiftUI customise panel.
///
/// - Parameters:
///   - domain: Same domain key passed to BannerView. The customise
///     panel inherits the parent banner's domain.
///   - visitorId: Same opaque per-install id used by BannerView.
///   - config: The already-loaded WidgetConfig (so the customise
///     panel doesn't re-fetch). Pass `config` from the banner's
///     successful load.
///   - isMinor: Whether DPDPA S.9 minor protections apply. Passed
///     through from BannerView's persisted audience state.
///   - onDone: Called once the user has saved or cancelled.
@available(iOS 15.0, *)
public struct PreferenceCenterView: View {
    private let domain: String
    private let visitorId: String
    private let config: WidgetConfig
    private let isMinor: Bool

    /// True when DPDPA S.9 minor mode is in effect — either the user
    /// self-identified as a minor OR the operator declared the site
    /// child-directed via WidgetConfig.behavior.childDirected. All
    /// purpose-toggle decisions in this view use this, not the raw
    /// `isMinor` parameter.
    private var effectiveMinor: Bool {
        if isMinor { return true }
        return (config.behavior?["childDirected"] ?? "").lowercased() == "true"
    }
    private let onDone: (PreferenceCenterDecision) -> Void

    /// Per-purpose toggle state. Initial value: `defaultOn` from the
    /// dashboard, OR forced-on for required + forced-off for
    /// non-essential under S.9 minor mode.
    @State private var selections: [String: Bool]
    @State private var inFlight: Bool = false
    @State private var saveError: String?

    public init(
        domain: String,
        visitorId: String,
        config: WidgetConfig,
        isMinor: Bool,
        onDone: @escaping (PreferenceCenterDecision) -> Void
    ) {
        self.domain = domain
        self.visitorId = visitorId
        self.config = config
        self.isMinor = isMinor
        self.onDone = onDone

        // Seed selections from the config's defaults, then apply
        // forced-on/off rules. We compute this once at init so the
        // user's interim taps aren't clobbered by re-renders.
        // Effective minor = user-selected (isMinor) OR operator-declared
        // child-directed (cfg.behavior.childDirected).
        let operatorChildDirected =
            (config.behavior?["childDirected"] ?? "").lowercased() == "true"
        let effectiveMinor = isMinor || operatorChildDirected
        var initial: [String: Bool] = [:]
        for purpose in config.categories {
            let forcedOn = purpose.required
            let forcedOff = effectiveMinor && !purpose.required
            initial[purpose.id] = forcedOn ? true : (forcedOff ? false : purpose.defaultOn)
        }
        _selections = State(initialValue: initial)
    }

    public var body: some View {
        let theme = BannerTheme.from(config)
        return VStack(alignment: .leading, spacing: 0) {
            header(theme: theme)
            Divider()
            // ScrollView so long category lists don't truncate on
            // small screens. Foreach over `config.categories` so the
            // order matches the dashboard config exactly.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(config.categories, id: \.id) { purpose in
                        purposeRow(purpose: purpose, theme: theme)
                        Divider()
                    }
                }
            }
            footer(theme: theme)
        }
        .background(theme.backgroundColor)
    }

    // MARK: - Header

    private func header(theme: BannerTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("foctta_preference_center_title"))
                .font(.title3.weight(.semibold))
                .foregroundColor(theme.textColor)
            Text(localized("foctta_customize_subtitle"))
                .font(.subheadline)
                .foregroundColor(theme.textColor.opacity(0.8))

            // S.9 disclaimer band, same coloured warning as on BannerView.
            // Visible only when minor mode is active. Keeps the user
            // oriented: even after entering the customise panel, the
            // restriction context is preserved.
            if effectiveMinor {
                Text(localized("foctta_minor_disclaimer"))
                    .font(.caption2)
                    .foregroundColor(Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
    }

    // MARK: - Purpose row

    private func purposeRow(purpose: Purpose, theme: BannerTheme) -> some View {
        let forcedOn = purpose.required
        let forcedOff = effectiveMinor && !purpose.required
        let bindingValue = Binding<Bool>(
            get: { selections[purpose.id] ?? purpose.defaultOn },
            set: { newValue in
                // Refuse mutations on forced rows — defensive belt
                // & braces; SwiftUI also disables the toggle visually.
                if forcedOn || forcedOff { return }
                selections[purpose.id] = newValue
            }
        )

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(purposeLabel(purpose))
                        .font(.body.weight(.medium))
                        .foregroundColor(theme.textColor)

                    if forcedOn {
                        badge(localized("foctta_purpose_required"), color: Color.gray)
                    } else if forcedOff {
                        badge(localized("foctta_s9_blocked"), color: Color.orange)
                    }
                }
                if let desc = purposeDescription(purpose), !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(theme.textColor.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: bindingValue)
                .labelsHidden()
                .disabled(forcedOn || forcedOff)
                .tint(theme.primaryColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: - Footer

    private func footer(theme: BannerTheme) -> some View {
        VStack(spacing: 8) {
            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 8) {
                Button(action: { onDone(.cancelled) }) {
                    Text(localized("foctta_button_close"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(theme.primaryColor, lineWidth: 1)
                )
                .foregroundColor(theme.primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: { Task { await save() } }) {
                    Text(localized("foctta_button_save"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .background(theme.primaryColor)
                .foregroundColor(theme.buttonTextColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(inFlight)
        }
        .padding(16)
    }

    // MARK: - Save

    /// Write the user's per-purpose selection as a custom consent log.
    /// ConsentService handles retry + offline-queue internally.
    private func save() async {
        inFlight = true
        defer { inFlight = false }
        saveError = nil

        // Final forced-rule sweep before sending — defends against any
        // state-corruption that bypassed the binding setter.
        var accepted: [String] = []
        var rejected: [String] = []
        for purpose in config.categories {
            let forcedOn = purpose.required
            let forcedOff = effectiveMinor && !purpose.required
            let effective: Bool
            if forcedOn { effective = true }
            else if forcedOff { effective = false }
            else { effective = selections[purpose.id] ?? purpose.defaultOn }
            if effective {
                accepted.append(purpose.id)
            } else {
                rejected.append(purpose.id)
            }
        }

        do {
            _ = try await FOCTTA.consent.record(
                domain: domain,
                visitorId: visitorId,
                action: .custom,
                categoriesAccepted: accepted,
                categoriesRejected: rejected,
                regulation: config.regulation ?? .dpdpa
            )
            onDone(.saved)
        } catch {
            // ConsentService enqueues retry-exhausted writes to the
            // offline queue, so the tap is durable. Surface the
            // human message to the user; they can choose to retry
            // or close.
            saveError = localized("foctta_error_offline_will_retry")
            // Treat as success at the navigation layer — the SDK
            // owns the write, the user is done.
            onDone(.saved)
        }
    }

    // MARK: - Helpers

    /// Prefer the dashboard-configured purpose label; fall back to the
    /// localised category name for the common IDs ("essential",
    /// "functional", "analytics", "marketing"). For unknown purpose
    /// IDs that have no label, return the id itself as a last resort.
    private func purposeLabel(_ purpose: Purpose) -> String {
        if !purpose.label.isEmpty { return purpose.label }
        switch purpose.id {
        case "essential": return localized("foctta_category_essential")
        case "functional": return localized("foctta_category_functional")
        case "analytics": return localized("foctta_category_analytics")
        case "marketing": return localized("foctta_category_marketing")
        default: return purpose.id
        }
    }

    /// Same fallback chain for the description.
    private func purposeDescription(_ purpose: Purpose) -> String? {
        if let d = purpose.description, !d.isEmpty { return d }
        switch purpose.id {
        case "essential": return localized("foctta_category_essential_description")
        case "functional": return localized("foctta_category_functional_description")
        case "analytics": return localized("foctta_category_analytics_description")
        case "marketing": return localized("foctta_category_marketing_description")
        default: return nil
        }
    }

    /// All 23 languages are bundled in `.lproj` resources at build time
    /// by `scripts/sync-sdk-translations.ts`. No runtime translation step.
    private func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}

// MARK: - UIKit wrapper

/// Wrap [PreferenceCenterView] for UIKit hosting apps. Same pattern
/// as [BannerViewController].
@available(iOS 15.0, *)
public final class PreferenceCenterViewController: UIHostingController<PreferenceCenterView> {
    public init(
        domain: String,
        visitorId: String,
        config: WidgetConfig,
        isMinor: Bool,
        onDone: @escaping (PreferenceCenterDecision) -> Void = { _ in }
    ) {
        super.init(
            rootView: PreferenceCenterView(
                domain: domain,
                visitorId: visitorId,
                config: config,
                isMinor: isMinor,
                onDone: { _ in }
            )
        )
        self.rootView = PreferenceCenterView(
            domain: domain,
            visitorId: visitorId,
            config: config,
            isMinor: isMinor
        ) { [weak self] decision in
            onDone(decision)
            self?.dismiss(animated: true)
        }
    }

    @MainActor required dynamic init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

#endif
