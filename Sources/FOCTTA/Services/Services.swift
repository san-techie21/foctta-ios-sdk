// Services.swift — ConsentService, RightsService, AuditService, ConfigService.
//
// One file because the services have small surface and live together
// conceptually. Splitting would just add ceremony.
//
// v1.0 auth model: slug-routed public endpoints, no API key. See
// Configuration for the rationale.

import Foundation
import CommonCrypto

// MARK: - ConsentService

public final class ConsentService: @unchecked Sendable {
    private let configuration: Configuration
    private let apiClient: APIClient
    private let idempotencyStore: IdempotencyStore
    private let offlineQueue: OfflineQueue
    private let receiptStore: ReceiptStore

    init(
        configuration: Configuration,
        apiClient: APIClient,
        idempotencyStore: IdempotencyStore,
        offlineQueue: OfflineQueue,
        receiptStore: ReceiptStore
    ) {
        self.configuration = configuration
        self.apiClient = apiClient
        self.idempotencyStore = idempotencyStore
        self.offlineQueue = offlineQueue
        self.receiptStore = receiptStore
    }

    /// Record a banner consent decision via POST /v1/cookie-consent-logs.
    /// Same endpoint the web cookie banner uses.
    @discardableResult
    public func record(
        domain: String,
        visitorId: String,
        action: ConsentAction,
        categoriesAccepted: [String] = [],
        categoriesRejected: [String] = [],
        regulation: Regulation = .dpdpa,
        bannerConfigId: String? = nil
    ) async throws -> ConsentMutationResult {
        let body = RecordConsentLogRequest(
            tenantId: configuration.tenantId,
            domain: domain,
            visitorId: visitorId,
            consentAction: action,
            categoriesAccepted: categoriesAccepted,
            categoriesRejected: categoriesRejected,
            regulation: regulation,
            userAgent: configuration.userAgent,
            bannerConfigId: bannerConfigId
        )
        let bodyData = try apiClient.encoder.encode(body)
        let opTag = "consent.record:\(visitorId):\(domain):\(action.rawValue)"
        let key = idempotencyStore.getOrCreate(operationTag: opTag)

        do {
            let envelope: RecordConsentLogEnvelope = try await apiClient.request(
                RequestSpec(
                    method: .POST,
                    path: Endpoints.consentLogRecord,
                    body: bodyData,
                    idempotencyKey: key
                ),
                as: RecordConsentLogEnvelope.self
            )
            idempotencyStore.clear(operationTag: opTag)
            receiptStore.append(envelope.receipt, eventType: "consent.recorded", entityId: envelope.data.id)
            return ConsentMutationResult(log: envelope.data, receipt: envelope.receipt)
        } catch let err as FocttaError {
            if case .network = err {
                _ = offlineQueue.enqueue(
                    operation: "consent.record",
                    method: "POST",
                    path: Endpoints.consentLogRecord,
                    body: bodyData,
                    idempotencyKey: key
                )
            }
            throw err
        }
    }

    /// Convenience: visitor tapped "Accept All" on a banner.
    @discardableResult
    public func acceptAll(
        domain: String,
        visitorId: String,
        availableCategories: [String],
        regulation: Regulation = .dpdpa
    ) async throws -> ConsentMutationResult {
        try await record(
            domain: domain,
            visitorId: visitorId,
            action: .acceptAll,
            categoriesAccepted: availableCategories,
            categoriesRejected: [],
            regulation: regulation
        )
    }

    /// Convenience: visitor tapped "Reject All". Functionally
    /// equivalent to "withdraw all consent" — most recent log wins.
    @discardableResult
    public func rejectAll(
        domain: String,
        visitorId: String,
        availableCategories: [String],
        regulation: Regulation = .dpdpa
    ) async throws -> ConsentMutationResult {
        try await record(
            domain: domain,
            visitorId: visitorId,
            action: .rejectAll,
            categoriesAccepted: [],
            categoriesRejected: availableCategories,
            regulation: regulation
        )
    }

    /// Check whether the visitor has consented to `purpose` on `domain`.
    /// Hits POST /v1/cookie-consent-logs/check (added 27 May 2026).
    public func check(
        domain: String,
        visitorId: String,
        purpose: String
    ) async throws -> CheckConsentResult {
        let body = CheckConsentLogRequest(
            tenantId: configuration.tenantId,
            domain: domain,
            visitorId: visitorId,
            purpose: purpose
        )
        let bodyData = try apiClient.encoder.encode(body)
        let envelope: CheckConsentLogEnvelope = try await apiClient.request(
            RequestSpec(method: .POST, path: Endpoints.consentLogCheck, body: bodyData),
            as: CheckConsentLogEnvelope.self
        )
        return envelope.data
    }
}

public struct ConsentMutationResult: Sendable {
    public let log: ConsentLogRecord
    public let receipt: ComplianceReceipt
}

// MARK: - RightsService

public final class RightsService: @unchecked Sendable {
    private let configuration: Configuration
    private let apiClient: APIClient
    private let idempotencyStore: IdempotencyStore
    private let receiptStore: ReceiptStore

    init(
        configuration: Configuration,
        apiClient: APIClient,
        idempotencyStore: IdempotencyStore,
        receiptStore: ReceiptStore
    ) {
        self.configuration = configuration
        self.apiClient = apiClient
        self.idempotencyStore = idempotencyStore
        self.receiptStore = receiptStore
    }

    /// File a DSAR / grievance / breach via the slug-routed public
    /// endpoint: POST /v1/dsar-requests/public/<tenantSlug>.
    @discardableResult
    public func fileDSAR(
        requestType: RequestType,
        identifiers: [String: String] = [:],
        regulation: Regulation = .dpdpa,
        description: String? = nil,
        contactEmail: String? = nil,
        contactMobile: String? = nil,
        language: String? = nil
    ) async throws -> DSARFilingResult {
        let body = FileDsarRequest(
            requestType: requestType,
            regulation: regulation,
            identifiers: identifiers,
            description: description,
            // Wire-shape field names — match CreatePublicDsarRequestSchema
            // in apps/api/src/modules/dsar/schemas.ts. See FileDsarRequest
            // doc comment in Models.swift for the rationale.
            requesterContactEmail: contactEmail,
            requesterContactMobile: contactMobile,
            language: language
        )
        let bodyData = try apiClient.encoder.encode(body)

        // Stable idempotency tag derived from the identifier set —
        // same submission produces the same key on retry, distinct
        // submissions produce distinct keys.
        let identifierSig = identifiers.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let opTag = "dsar.file:\(requestType.rawValue):\(identifierSig.hashValue)"
        let key = idempotencyStore.getOrCreate(operationTag: opTag)

        let envelope: FileDsarEnvelope = try await apiClient.request(
            RequestSpec(
                method: .POST,
                path: Endpoints.dsarSubmit(tenantSlug: configuration.tenantSlug),
                body: bodyData,
                idempotencyKey: key
            ),
            as: FileDsarEnvelope.self
        )
        idempotencyStore.clear(operationTag: opTag)
        if let receipt = envelope.receipt {
            receiptStore.append(receipt, eventType: "dsar.filed", entityId: envelope.data.id)
        }
        return DSARFilingResult(dsar: envelope.data, receipt: envelope.receipt)
    }

    /// Rule 14 erasure convenience.
    @discardableResult
    public func requestErasure(
        identifiers: [String: String],
        reason: String? = nil
    ) async throws -> DSARFilingResult {
        try await fileDSAR(
            requestType: .erasure,
            identifiers: identifiers,
            description: reason
        )
    }

    /// Rule 11 access request.
    @discardableResult
    public func requestAccess(
        identifiers: [String: String],
        contactEmail: String? = nil,
        contactMobile: String? = nil
    ) async throws -> DSARFilingResult {
        try await fileDSAR(
            requestType: .access,
            identifiers: identifiers,
            contactEmail: contactEmail,
            contactMobile: contactMobile
        )
    }

    /// Fetch the tenant's Rights Portal widget configuration.
    ///
    /// Returns the identifier set (per DPDPA Rule 14(5)), supported
    /// rights, primary regulation, theme colours, guardian-filing
    /// flags, and other per-tenant config the SDK uses to render the
    /// in-app [RightsPortalView] dynamically.
    ///
    /// Customer integrations MUST call this before showing
    /// RightsPortalView — otherwise the SDK falls back to the generic
    /// identifier shape (email / mobile / customerId) which won't
    /// match enterprise tenants whose required identifiers differ.
    ///
    /// Example for `motilal-oswal` returns identifiers
    /// `[emailAddress, phoneNumber, cif]` — passing those keys is
    /// required for the DSAR submission to validate server-side.
    public func getRightsPortalConfig(
        tenantSlug: String? = nil
    ) async throws -> RightsPortalWidgetConfig {
        let slug = tenantSlug ?? configuration.tenantSlug
        let envelope: RightsPortalWidgetConfigEnvelope = try await apiClient.request(
            RequestSpec(
                method: .GET,
                path: Endpoints.rightsPortalConfig(tenantSlug: slug)
            ),
            as: RightsPortalWidgetConfigEnvelope.self
        )
        return envelope.data
    }

    /// Convenience — file a grievance.
    @discardableResult
    public func fileGrievance(
        identifiers: [String: String],
        description: String,
        contactEmail: String? = nil
    ) async throws -> DSARFilingResult {
        try await fileDSAR(
            requestType: .objection,
            identifiers: identifiers,
            description: description,
            contactEmail: contactEmail
        )
    }
}

public struct DSARFilingResult: Sendable {
    public let dsar: DsarRequestResponse
    public let receipt: ComplianceReceipt?
}

// MARK: - AuditService

public final class AuditService: @unchecked Sendable {
    private let apiClient: APIClient
    private let receiptStore: ReceiptStore

    init(apiClient: APIClient, receiptStore: ReceiptStore) {
        self.apiClient = apiClient
        self.receiptStore = receiptStore
    }

    public func history() -> [StoredReceipt] { receiptStore.all() }

    public func observeHistory(_ block: @escaping ([StoredReceipt]) -> Void) {
        receiptStore.observe(block)
    }

    /// Recompute eventHash locally; compare to server-provided value.
    public func validate(_ receipt: StoredReceipt, canonicalPayload: Data) -> ValidationResult {
        let recomputed = sha256Hex(canonicalPayload)
        let expected = receipt.eventHash.hasPrefix("sha256:")
            ? String(receipt.eventHash.dropFirst("sha256:".count))
            : receipt.eventHash
        return recomputed.lowercased() == expected.lowercased()
            ? .valid
            : .invalid(expected: receipt.eventHash, got: "sha256:\(recomputed)")
    }

    /// Walk the local cache and verify chain continuity.
    public func validateChain() -> ChainValidationResult {
        let receipts = receiptStore.all().sorted { $0.chainPosition < $1.chainPosition }
        guard receipts.count >= 2 else {
            return ChainValidationResult(intact: true, breaks: [])
        }
        var breaks: [ChainBreak] = []
        for i in 1..<receipts.count {
            let prev = receipts[i - 1]
            let curr = receipts[i]
            if curr.previousHash != prev.eventHash {
                breaks.append(ChainBreak(
                    position: curr.chainPosition,
                    expected: prev.eventHash,
                    actual: curr.previousHash
                ))
            }
        }
        return ChainValidationResult(intact: breaks.isEmpty, breaks: breaks)
    }

    private func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ValidationResult: Sendable, Equatable {
    case valid
    case invalid(expected: String, got: String)
}

public struct ChainValidationResult: Sendable, Equatable {
    public let intact: Bool
    public let breaks: [ChainBreak]
}

public struct ChainBreak: Sendable, Equatable {
    public let position: Int64
    public let expected: String
    public let actual: String?
}

// MARK: - ConfigService

public final class ConfigService: @unchecked Sendable {
    private let configuration: Configuration
    private let apiClient: APIClient
    private let ttl: TimeInterval = 24 * 60 * 60
    private let cacheFile: URL

    init(configuration: Configuration, apiClient: APIClient) {
        self.configuration = configuration
        self.apiClient = apiClient
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FOCTTA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheFile = dir.appendingPathComponent("widget-config.json")
    }

    public func get(domain: String, forceRefresh: Bool = false) async throws -> WidgetConfig {
        if !forceRefresh, let cached = loadCached(domain: domain) { return cached }
        return try await refresh(domain: domain)
    }

    public func refresh(domain: String) async throws -> WidgetConfig {
        let envelope: WidgetConfigEnvelope = try await apiClient.request(
            RequestSpec(
                method: .GET,
                path: Endpoints.bannerConfig(tenantId: configuration.tenantId, domain: domain)
            ),
            as: WidgetConfigEnvelope.self
        )
        persistCached(domain: domain, config: envelope.data)
        return envelope.data
    }

    private struct CachedEntry: Codable {
        let domain: String
        let cachedAt: TimeInterval
        let config: WidgetConfig
    }

    private func loadCached(domain: String) -> WidgetConfig? {
        guard let data = try? Data(contentsOf: cacheFile), !data.isEmpty else { return nil }
        guard let entry = try? JSONDecoder().decode(CachedEntry.self, from: data) else { return nil }
        guard entry.domain == domain else { return nil }
        let age = Date().timeIntervalSince1970 - entry.cachedAt
        return age <= ttl ? entry.config : nil
    }

    private func persistCached(domain: String, config: WidgetConfig) {
        let entry = CachedEntry(domain: domain, cachedAt: Date().timeIntervalSince1970, config: config)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let tmp = cacheFile.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(cacheFile, withItemAt: tmp)
    }
}
