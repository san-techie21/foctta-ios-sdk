// Models.swift — public Codable types matching FOCTTA backend schemas.
//
// All field names use camelCase on the Swift side and match the
// backend JSON exactly (which is also camelCase across the wire).
//
// Mirrors packages/sdk-android/foctta/src/main/kotlin/com/foctta/sdk/models/Models.kt
// — keep both in sync; the scripts/gen-sdk-types.ts drift checker
// enforces this in CI.

import Foundation

public enum Regulation: String, Codable, Sendable {
    case dpdpa = "DPDPA"
    case gdpr = "GDPR"
    case ccpa = "CCPA"
}

/// Banner consent action — what the visitor did when shown the banner.
/// Mirrors apps/api/src/modules/cookie-banners/schemas.ts.
public enum ConsentAction: String, Codable, Sendable {
    case acceptAll = "accept_all"
    case rejectAll = "reject_all"
    case custom
    case dismiss
}

public enum RequestType: String, Codable, Sendable, CaseIterable {
    case access, correction, erasure, portability, objection, withdrawal, nomination
}

// MARK: - Compliance receipt

/// Hash-chained per tenant. Recompute eventHash locally to verify
/// integrity (see ``AuditService/validate(_:canonicalPayload:)``).
///
/// Wire-format note (verified 27 May 2026 against staging):
///  - The cookie-banner receipt returns `id` on the wire and no
///    `signature` field.
///  - The formal audit module's receipt (used by /v1/audit endpoints)
///    returns `receiptId` and `signature`.
///
/// We expose `receiptId` as the stable SDK API surface and use a
/// custom `CodingKeys` mapping that accepts either wire shape. `signature`
/// is optional because cookie-banner receipts omit it.
public struct ComplianceReceipt: Codable, Sendable, Equatable {
    public let receiptId: String
    public let eventType: String
    public let eventHash: String
    public let previousHash: String?
    public let chainPosition: Int64
    public let signature: String?
    public let timestamp: String

    private enum CodingKeys: String, CodingKey {
        case receiptId
        case id // alternate wire field for cookie-banner receipts
        case eventType
        case eventHash
        case previousHash
        case chainPosition
        case signature
        case timestamp
    }

    public init(
        receiptId: String,
        eventType: String,
        eventHash: String,
        previousHash: String? = nil,
        chainPosition: Int64,
        signature: String? = nil,
        timestamp: String
    ) {
        self.receiptId = receiptId
        self.eventType = eventType
        self.eventHash = eventHash
        self.previousHash = previousHash
        self.chainPosition = chainPosition
        self.signature = signature
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept either wire field; prefer `receiptId` (audit shape),
        // fall back to `id` (cookie-banner shape).
        if let rid = try c.decodeIfPresent(String.self, forKey: .receiptId) {
            self.receiptId = rid
        } else {
            self.receiptId = try c.decode(String.self, forKey: .id)
        }
        self.eventType = try c.decode(String.self, forKey: .eventType)
        self.eventHash = try c.decode(String.self, forKey: .eventHash)
        self.previousHash = try c.decodeIfPresent(String.self, forKey: .previousHash)
        self.chainPosition = try c.decode(Int64.self, forKey: .chainPosition)
        self.signature = try c.decodeIfPresent(String.self, forKey: .signature)
        self.timestamp = try c.decode(String.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(receiptId, forKey: .receiptId)
        try c.encode(eventType, forKey: .eventType)
        try c.encode(eventHash, forKey: .eventHash)
        try c.encodeIfPresent(previousHash, forKey: .previousHash)
        try c.encode(chainPosition, forKey: .chainPosition)
        try c.encodeIfPresent(signature, forKey: .signature)
        try c.encode(timestamp, forKey: .timestamp)
    }
}

// MARK: - Consent (cookie-consent-logs shape)

struct RecordConsentLogRequest: Codable {
    let tenantId: String
    let domain: String
    let visitorId: String?
    let consentAction: ConsentAction
    let categoriesAccepted: [String]
    let categoriesRejected: [String]
    let regulation: Regulation?
    let userAgent: String?
    let bannerConfigId: String?
}

public struct ConsentLogRecord: Codable, Sendable {
    public let id: String
    public let tenantId: String
    public let domain: String
    public let visitorId: String?
    public let consentAction: ConsentAction
    public let categoriesAccepted: [String]
    public let categoriesRejected: [String]
    public let regulation: Regulation?
    public let createdAt: String
}

struct RecordConsentLogEnvelope: Codable {
    let data: ConsentLogRecord
    let receipt: ComplianceReceipt
}

/// Body for POST /v1/cookie-consent-logs/check.
struct CheckConsentLogRequest: Codable {
    let tenantId: String
    let domain: String
    let visitorId: String
    let purpose: String
}

public struct CheckConsentResult: Codable, Sendable {
    public let hasConsent: Bool
    public let lastDecisionAt: String?
    public let consentAction: ConsentAction?
    public let regulation: Regulation?
}

struct CheckConsentLogEnvelope: Codable { let data: CheckConsentResult }

// MARK: - DSAR / Rights

/// Wire-shape for POST /v1/dsar-requests/public/<tenantSlug>.
///
/// Field names MUST match `CreatePublicDsarRequestSchema` in
/// `apps/api/src/modules/dsar/schemas.ts`. The naming is
/// `requesterContactEmail` / `requesterContactMobile` (not
/// `contactEmail` / `contactMobile`) because the rights-portal widget
/// uses "requester" prefixes to disambiguate from `guardianEmail` /
/// `nomineeEmail` that appear elsewhere in the body for child / nominee
/// filings.
///
/// The PUBLIC SDK surface keeps `contactEmail` / `contactMobile` as
/// parameter names (see RightsService.fileDSAR) so v0.1.0-beta.1
/// consumers don't break — we just rewrite the field names at the
/// Codable layer here.
struct FileDsarRequest: Codable {
    let requestType: RequestType
    let regulation: Regulation
    let identifiers: [String: String]
    let description: String?
    let requesterContactEmail: String?
    let requesterContactMobile: String?
    let language: String?
}

public struct DsarRequestResponse: Codable, Sendable {
    public let id: String
    public let referenceNumber: String
    public let status: String
    public let slaDeadline: String?
    public let createdAt: String
}

struct FileDsarEnvelope: Codable {
    let data: DsarRequestResponse
    let receipt: ComplianceReceipt?
}

// MARK: - Widget / banner config

/// Banner config returned by GET /v1/cookie-banners/public/:tenantId/:domain.
///
/// Lightly typed for v1.0; v1.1 (native UI) will type every nested
/// object precisely. JSONDecoder ignores unknown keys, so backend
/// additions don't break older SDK versions.
public struct WidgetConfig: Codable, Sendable {
    public let layout: String?
    public let position: String?
    public let theme: String?
    public let colors: [String: String]?
    public let content: [String: String]?
    public let buttons: [String: String]?
    public let categories: [Purpose]
    public let behavior: [String: String]?
    public let regulation: Regulation?
    public let scriptRules: [String: String]?

    public init(
        layout: String? = nil,
        position: String? = nil,
        theme: String? = nil,
        colors: [String: String]? = nil,
        content: [String: String]? = nil,
        buttons: [String: String]? = nil,
        categories: [Purpose] = [],
        behavior: [String: String]? = nil,
        regulation: Regulation? = nil,
        scriptRules: [String: String]? = nil
    ) {
        self.layout = layout
        self.position = position
        self.theme = theme
        self.colors = colors
        self.content = content
        self.buttons = buttons
        self.categories = categories
        self.behavior = behavior
        self.regulation = regulation
        self.scriptRules = scriptRules
    }
}

public struct Purpose: Codable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
    public let required: Bool
    public let defaultOn: Bool
}

struct WidgetConfigEnvelope: Codable { let data: WidgetConfig }

// MARK: - Rights Portal widget config

/// Per-tenant Rights Portal widget configuration returned by
/// `GET /v1/dsar-requests/public/<tenantSlug>/widget-config`.
///
/// DPDPA Rule 14(5) requires each Data Fiduciary to publish the
/// identifier set they need to resolve a Data Principal. The server
/// returns it here; the SDK uses it to render the in-app
/// [RightsPortalView]'s identifier fields DYNAMICALLY — instead of
/// hardcoding `email`/`mobile`/`customerId`, the SDK reads
/// `config.identifiers` and renders one field per entry with the
/// tenant's exact key + label + helpText + required flag.
///
/// Customer apps that integrate with FOCTTA **must** fetch this
/// before showing the rights portal — without it, the SDK falls back
/// to the generic identifier shape (email / mobile / customerId)
/// which won't match enterprise tenants like Motilal Oswal whose
/// required keys are `emailAddress` / `phoneNumber` / `cif`.
public struct RightsPortalWidgetConfig: Codable, Sendable {
    public let enabled: Bool
    public let version: String?
    public let tenantSlug: String
    public let tenantName: String?
    public let title: String?
    public let subtitle: String?
    public let identifiers: [RightsPortalIdentifier]
    public let rights: [String]
    public let primaryRegulation: Regulation?
    public let supportedRegulations: [Regulation]?
    public let languages: [String]?
    public let primaryColor: String?
    public let position: String?
    public let contactEmail: String?
    public let isSdf: Bool?
    public let hasPrincipalLookupConnector: Bool?
    public let guardianFiling: RightsPortalGuardianFiling?

    public init(
        enabled: Bool,
        version: String? = nil,
        tenantSlug: String,
        tenantName: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        identifiers: [RightsPortalIdentifier] = [],
        rights: [String] = [],
        primaryRegulation: Regulation? = nil,
        supportedRegulations: [Regulation]? = nil,
        languages: [String]? = nil,
        primaryColor: String? = nil,
        position: String? = nil,
        contactEmail: String? = nil,
        isSdf: Bool? = nil,
        hasPrincipalLookupConnector: Bool? = nil,
        guardianFiling: RightsPortalGuardianFiling? = nil
    ) {
        self.enabled = enabled
        self.version = version
        self.tenantSlug = tenantSlug
        self.tenantName = tenantName
        self.title = title
        self.subtitle = subtitle
        self.identifiers = identifiers
        self.rights = rights
        self.primaryRegulation = primaryRegulation
        self.supportedRegulations = supportedRegulations
        self.languages = languages
        self.primaryColor = primaryColor
        self.position = position
        self.contactEmail = contactEmail
        self.isSdf = isSdf
        self.hasPrincipalLookupConnector = hasPrincipalLookupConnector
        self.guardianFiling = guardianFiling
    }
}

/// A single identifier the tenant requires (or accepts) from the Data
/// Principal — e.g. `{key: "phoneNumber", label: "Phone Number",
/// required: true}`. The SDK renders one TextField per entry.
public struct RightsPortalIdentifier: Codable, Sendable, Identifiable {
    /// Stable key used as the dictionary key in the DSAR submission
    /// `identifiers` map. MUST exactly match the tenant's expected key
    /// — server validation rejects unknown keys + missing required ones.
    public let key: String
    /// User-facing label shown above the TextField.
    public let label: String
    /// Optional one-line help text shown below the TextField.
    public let helpText: String?
    /// When `true`, the user can't submit until this field has a value.
    public let required: Bool
    /// Grouping hint for the UI (e.g. "Contact Details", "Financial
    /// Info"). The SDK ignores this for v1.0 — flat list rendering.
    public let category: String?

    public var id: String { key }

    public init(
        key: String,
        label: String,
        helpText: String? = nil,
        required: Bool = false,
        category: String? = nil
    ) {
        self.key = key
        self.label = label
        self.helpText = helpText
        self.required = required
        self.category = category
    }
}

/// DPDPA Section 9 + Rule 10/11 guardian-filing block. Returned when
/// the tenant has enabled minor / disability-flow filings via their
/// dashboard. The SDK reads this to decide whether to render the
/// guardian fields in the rights portal — v1.0 SDK doesn't render
/// them yet (deferred to v1.x DigiLocker mobile work); only the type
/// is shipped so a future SDK release can light up the UI without a
/// breaking model change.
public struct RightsPortalGuardianFiling: Codable, Sendable {
    public let enabled: Bool
    public let acceptedVerificationMethods: [String]?
    public let acceptedRelationships: [String]?
    public let requireMobile: Bool?
    public let requireDisabilityProof: Bool?
    public let behaviouralMonitoringDisabled: Bool?
    public let childAgeThreshold: Int?
}

struct RightsPortalWidgetConfigEnvelope: Codable {
    let data: RightsPortalWidgetConfig
}
