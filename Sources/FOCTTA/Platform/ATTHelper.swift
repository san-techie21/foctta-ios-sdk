// ATTHelper.swift — App Tracking Transparency integration.
//
// Important design note (May 2026): competitor research showed customers
// hate SDKs that own the ATT prompt and bundle it with consent. This
// helper does NOT auto-prompt or auto-record by default; it provides
// helpers that the customer's app calls at its chosen moment, then
// records consent for `device_advertising_id` purpose if the user
// authorised.

import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
import AdSupport
#endif

/// iOS-specific helpers exposed via `FOCTTA.iOS`.
public final class IOSAPI: @unchecked Sendable {
    private let consentService: ConsentService

    init(consentService: ConsentService) {
        self.consentService = consentService
    }

    /// Result of an ATT prompt.
    public enum ATTResult: Sendable {
        /// User authorised tracking — IDFA is the device advertising id.
        case authorized(idfa: String)
        case denied
        case restricted
        case notDetermined
        /// Platform doesn't support ATT (iOS < 14.5 or simulator).
        case unsupported
    }

    /// Result of `requestATTAndRecordConsent`. Both authorise AND deny
    /// outcomes produce a receipt — the consent log captures the user's
    /// actual decision (yes/no), not just the absence of one. Only
    /// `restricted` (parental controls / MDM block) and `unsupported`
    /// (iOS < 14.5) lack a receipt because the user never had a chance
    /// to make an explicit decision.
    public enum ATTConsentResult: Sendable {
        case recorded(att: ATTResult, receipt: ComplianceReceipt)
        /// User saw the ATT prompt and denied. Receipt records the
        /// explicit rejection of `device_advertising_id`.
        case deniedRecorded(receipt: ComplianceReceipt)
        case restricted
        case unsupported
    }

    /// Read current ATT status without prompting.
    public func currentATTStatus() -> ATTResult {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14.5, *) {
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .authorized:
                let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                return .authorized(idfa: idfa)
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
        #endif
        return .unsupported
    }

    /// Request ATT permission. Just the prompt — no FOCTTA consent
    /// recording. Caller decides whether to follow up.
    @available(iOS 14.5, *)
    public func requestATT() async -> ATTResult {
        #if canImport(AppTrackingTransparency)
        let status = await ATTrackingManager.requestTrackingAuthorization()
        switch status {
        case .authorized:
            let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            return .authorized(idfa: idfa)
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
        #else
        return .unsupported
        #endif
    }

    /// Convenience: request ATT and record consent for the
    /// `device_advertising_id` category via the cookie-consent-logs
    /// endpoint — for BOTH authorise and deny outcomes (so the consent
    /// log captures the user's actual decision either way).
    ///
    /// v1.0 records this as a `custom` consent action. The visitor
    /// must already have accepted the broader marketing category via
    /// the banner; this records a finer-grained per-device-id
    /// confirmation.
    ///
    /// **Info.plist requirement:** the host app MUST declare
    /// `NSUserTrackingUsageDescription` (a user-facing string explaining
    /// why ATT is requested) — Apple silently rejects the prompt
    /// otherwise. Example:
    ///
    /// ```xml
    /// <key>NSUserTrackingUsageDescription</key>
    /// <string>We use your advertising ID to personalise the ads you see.</string>
    /// ```
    ///
    /// - Parameter domain: The host the consent is associated with.
    ///   For mobile apps this is typically the customer's app domain
    ///   or a bundle-id-mapped FOCTTA banner config domain.
    /// - Parameter visitorId: Opaque per-visitor / per-install id.
    @available(iOS 14.5, *)
    public func requestATTAndRecordConsent(
        domain: String,
        visitorId: String,
        regulation: Regulation = .dpdpa
    ) async throws -> ATTConsentResult {
        let attResult = await requestATT()
        switch attResult {
        case .authorized:
            let mutation = try await consentService.record(
                domain: domain,
                visitorId: visitorId,
                action: .custom,
                categoriesAccepted: ["device_advertising_id"],
                categoriesRejected: [],
                regulation: regulation
            )
            return .recorded(att: attResult, receipt: mutation.receipt)
        case .denied:
            // Explicit denial is a real user decision — record it so
            // the audit trail shows the rejection (not just an absence
            // of consent, which could mean "user dismissed without
            // deciding" and look indistinguishable in downstream
            // systems).
            let mutation = try await consentService.record(
                domain: domain,
                visitorId: visitorId,
                action: .custom,
                categoriesAccepted: [],
                categoriesRejected: ["device_advertising_id"],
                regulation: regulation
            )
            return .deniedRecorded(receipt: mutation.receipt)
        case .restricted: return .restricted
        case .notDetermined, .unsupported: return .unsupported
        }
    }
}
