// FOCTTA.swift — public facade and configuration.
//
// Customers see exactly this file plus the four service classes' public
// methods. Internal types under FOCTTA/Network, FOCTTA/Storage,
// FOCTTA/Platform are implementation details.

import Foundation

/// SDK environment — picks the default base URL.
///
/// For dedicated-DB tenants (e.g. `motilal-oswal.foctta.com`) use
/// `.production` and pass an explicit `baseURL` override on
/// ``Configuration``.
public enum Environment: Sendable {
    case production
    case staging

    public var defaultBaseURL: String {
        switch self {
        case .production: return "https://app.foctta.com/v1"
        case .staging: return "https://app.staging.foctta.com/v1"
        }
    }
}

/// Immutable SDK configuration. Validated when passed to
/// ``FOCTTA/configure(_:)``; invalid values throw
/// ``FocttaError/validation(message:)``.
///
/// ## Auth model (v1.0)
///
/// Unlike Stripe-style "public API key" SDKs, the FOCTTA mobile SDK
/// does **NOT** embed an API key in the app binary. Instead it uses
/// the same slug-routed public endpoints the web cookie banner uses
/// (`POST /v1/cookie-consent-logs`, `GET /v1/cookie-banners/public/...`).
///
/// Authentication happens through:
///  - **tenantSlug** in the URL path for DSAR / rights flows
///    (`/v1/dsar-requests/public/<slug>/...`).
///  - **tenantId** in the request body for consent flows.
///  - **Backend rate limits** per tenantId + per IP hash to bound
///    abuse from a binary-extracted slug/id.
///
/// This is more secure than the public-key model (no key to extract
/// from the binary) and architecturally consistent with the web widget.
public struct Configuration: Sendable {
    /// Tenant slug as appears in the FOCTTA subdomain
    /// (e.g. `motilal-oswal` for `motilal-oswal.foctta.com`). Used to
    /// build slug-routed URLs. Public information — not a secret.
    public let tenantSlug: String

    /// Tenant UUID. Used in request bodies for consent flows. Must
    /// match the `tenantSlug`'s bound tenant.
    public let tenantId: String

    public let environment: Environment

    /// Optional override (e.g. for self-hosted / dedicated-DB tenant
    /// subdomains). Must use https.
    public let baseURL: String?

    public let timeoutSeconds: TimeInterval

    public let maxRetries: Int

    public let enableLogging: Bool

    public let userAgent: String

    public init(
        tenantSlug: String,
        tenantId: String,
        environment: Environment = .production,
        baseURL: String? = nil,
        timeoutSeconds: TimeInterval = 10,
        maxRetries: Int = 3,
        enableLogging: Bool = false,
        userAgent: String = "foctta-ios-sdk/\(Configuration.sdkVersion)"
    ) {
        self.tenantSlug = tenantSlug
        self.tenantId = tenantId
        self.environment = environment
        self.baseURL = baseURL
        self.timeoutSeconds = timeoutSeconds
        self.maxRetries = maxRetries
        self.enableLogging = enableLogging
        self.userAgent = userAgent
    }

    public static let sdkVersion = "0.1.0"

    /// Resolved base URL — explicit override or environment default.
    public var resolvedBaseURL: String {
        let url = baseURL ?? environment.defaultBaseURL
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    func validate() throws {
        guard !tenantSlug.isEmpty else {
            throw FocttaError.validation(message: "tenantSlug must not be blank.")
        }
        guard Self.slugRegex.firstMatch(
            in: tenantSlug,
            range: NSRange(location: 0, length: tenantSlug.utf16.count)
        ) != nil else {
            throw FocttaError.validation(
                message: "tenantSlug must be lowercase alphanumeric with hyphens (e.g. 'motilal-oswal'). Got: '\(tenantSlug)'"
            )
        }
        guard !tenantId.isEmpty else {
            throw FocttaError.validation(message: "tenantId must not be blank.")
        }
        guard Self.uuidRegex.firstMatch(
            in: tenantId,
            range: NSRange(location: 0, length: tenantId.utf16.count)
        ) != nil else {
            throw FocttaError.validation(message: "tenantId must be a UUID.")
        }
        if let baseURL = baseURL {
            guard baseURL.hasPrefix("https://") else {
                throw FocttaError.validation(
                    message: "baseURL must use https:// — http endpoints are rejected. Got: \(baseURL)"
                )
            }
        }
        guard (1.0...60.0).contains(timeoutSeconds) else {
            throw FocttaError.validation(
                message: "timeoutSeconds must be 1...60. Got: \(timeoutSeconds)"
            )
        }
        guard (0...5).contains(maxRetries) else {
            throw FocttaError.validation(message: "maxRetries must be 0...5. Got: \(maxRetries)")
        }
    }

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    )

    // Tenant slug — lowercase alphanumeric with hyphens. Matches
    // server-side validation in apps/api.
    private static let slugRegex = try! NSRegularExpression(
        pattern: "^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$"
    )
}

/// Public facade — configure once at app launch, then call into the
/// namespaced services.
///
/// ```swift
/// // top of AppDelegate.application(_:didFinishLaunchingWithOptions:)
/// try? FOCTTA.configure(.init(
///     tenantSlug: "motilal-oswal",
///     tenantId: "00000000-0000-4000-9100-000000000001",
///     environment: .production
/// ))
///
/// // record consent (slug-routed public endpoint)
/// let result = try await FOCTTA.consent.acceptAll(
///     domain: "your-app-domain.com",
///     visitorId: persistentVisitorId,
///     availableCategories: ["functional", "analytics", "marketing"],
///     regulation: .dpdpa
/// )
/// ```
public enum FOCTTA {

    private static var state: SdkState?
    private static let lock = NSLock()

    /// Initialise the SDK. Must be called before any other FOCTTA API.
    public static func configure(_ configuration: Configuration) throws {
        try configuration.validate()
        let apiClient = APIClient(configuration: configuration)
        let idempotencyStore = IdempotencyStore()
        let receiptStore = ReceiptStore()
        let offlineQueue = OfflineQueue()
        let newState = SdkState(
            configuration: configuration,
            apiClient: apiClient,
            consentService: ConsentService(
                configuration: configuration,
                apiClient: apiClient,
                idempotencyStore: idempotencyStore,
                offlineQueue: offlineQueue,
                receiptStore: receiptStore
            ),
            rightsService: RightsService(
                configuration: configuration,
                apiClient: apiClient,
                idempotencyStore: idempotencyStore,
                receiptStore: receiptStore
            ),
            auditService: AuditService(apiClient: apiClient, receiptStore: receiptStore),
            configService: ConfigService(configuration: configuration, apiClient: apiClient)
        )
        lock.lock()
        defer { lock.unlock() }
        state = newState
    }

    public static var consent: ConsentService { requireState().consentService }
    public static var rights: RightsService { requireState().rightsService }
    public static var audit: AuditService { requireState().auditService }
    public static var config: ConfigService { requireState().configService }

    /// The SDK's resolved configuration, or `nil` if `FOCTTA.configure(_:)`
    /// hasn't been called yet. Internal-only — host apps shouldn't peek
    /// at the configuration directly; this exposure exists so SDK
    /// internals can reach the base URL without going through the public
    /// service surface.
    internal static var configurationOrNil: Configuration? {
        lock.lock()
        defer { lock.unlock() }
        return state?.configuration
    }

    /// iOS-specific platform helpers (ATT).
    public static var iOS: IOSAPI {
        let s = requireState()
        return IOSAPI(consentService: s.consentService)
    }

    public static var isConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != nil
    }

    static func requireState() -> SdkState {
        lock.lock()
        defer { lock.unlock() }
        guard let s = state else {
            fatalError("FOCTTA is not configured. Call FOCTTA.configure(...) before using any SDK API.")
        }
        return s
    }
}

/// Bundles wired services + dependencies for a single configured SDK instance.
final class SdkState: @unchecked Sendable {
    let configuration: Configuration
    let apiClient: APIClient
    let consentService: ConsentService
    let rightsService: RightsService
    let auditService: AuditService
    let configService: ConfigService

    init(
        configuration: Configuration,
        apiClient: APIClient,
        consentService: ConsentService,
        rightsService: RightsService,
        auditService: AuditService,
        configService: ConfigService
    ) {
        self.configuration = configuration
        self.apiClient = apiClient
        self.consentService = consentService
        self.rightsService = rightsService
        self.auditService = auditService
        self.configService = configService
    }
}
