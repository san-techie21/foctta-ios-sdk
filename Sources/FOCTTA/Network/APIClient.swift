// APIClient.swift — HTTP client backing every FOCTTA service.
//
// URLSession + async/await. No Alamofire (smaller transitive footprint,
// audit-friendly for BFSI). Retry 1s/2s/4s, max maxRetries attempts;
// 4xx (except 429) throws immediately, 5xx + 429 retry.

import Foundation

/// Errors surfaced to callers. Catch ``FocttaError`` to handle all;
/// branch on cases for retry strategy.
public enum FocttaError: Error, CustomStringConvertible, Sendable {
    /// Caller violated the API contract.
    case validation(message: String)

    /// Server returned a permanent 4xx (not 429). Don't retry.
    case api(status: Int, problemDetail: ProblemDetail?, message: String)

    /// Server returned a retryable failure (5xx, 429) and retries exhausted.
    case server(status: Int, attemptCount: Int, message: String)

    /// Network never delivered a response. Replay is safe (idempotency key).
    case network(attemptCount: Int, message: String, underlying: (any Error)?)

    /// SDK called before ``FOCTTA/configure(_:)``.
    case notConfigured

    public var description: String {
        switch self {
        case .validation(let m): return "FocttaError.validation: \(m)"
        case .api(let s, _, let m): return "FocttaError.api(\(s)): \(m)"
        case .server(let s, let a, let m): return "FocttaError.server(\(s), \(a)x): \(m)"
        case .network(let a, let m, _): return "FocttaError.network(\(a)x): \(m)"
        case .notConfigured: return "FocttaError.notConfigured"
        }
    }
}

/// RFC 7807 Problem Details — what FOCTTA returns on 4xx.
public struct ProblemDetail: Codable, Sendable {
    public let type: String?
    public let title: String?
    public let status: Int?
    public let detail: String?
    public let instance: String?
    public let errors: [String: [String]]?
}

enum HTTPMethod: String { case GET, POST, PUT, PATCH, DELETE }

struct RequestSpec {
    let method: HTTPMethod
    let path: String
    let body: Data?
    let idempotencyKey: String?
    let headers: [String: String]

    init(
        method: HTTPMethod,
        path: String,
        body: Data? = nil,
        idempotencyKey: String? = nil,
        headers: [String: String] = [:]
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.idempotencyKey = idempotencyKey
        self.headers = headers
    }
}

/// Slug-routed public endpoint paths. See
/// `packages/sdk-android/foctta/src/main/kotlin/com/foctta/sdk/network/Endpoints.kt`
/// for the parallel Android constants — keep them in sync.
enum Endpoints {
    // Consent — same endpoints the web cookie banner uses.
    static let consentLogRecord = "/cookie-consent-logs"
    /// Public consent-check, added 27 May 2026 for the mobile SDK.
    static let consentLogCheck = "/cookie-consent-logs/check"
    /// Banner config — purposes, colours, copy. Public, no auth.
    static func bannerConfig(tenantId: String, domain: String) -> String {
        "/cookie-banners/public/\(tenantId)/\(domain)"
    }

    // DSAR / Rights — slug-routed public Rights Portal endpoints.
    static func dsarSubmit(tenantSlug: String) -> String {
        "/dsar-requests/public/\(tenantSlug)"
    }
    static func dsarStatus(tenantSlug: String) -> String {
        "/dsar-requests/public/\(tenantSlug)/status"
    }
    static func rightsPortalConfig(tenantSlug: String) -> String {
        "/dsar-requests/public/\(tenantSlug)/widget-config"
    }

    // Withdrawal is v1.1 — see ConsentService doc.
}

final class APIClient: @unchecked Sendable {
    private let configuration: Configuration
    private let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = configuration.timeoutSeconds
        cfg.timeoutIntervalForResource = configuration.timeoutSeconds * 2
        self.session = session ?? URLSession(configuration: cfg)

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// Execute a request and decode the response body to `T`.
    func request<T: Decodable>(_ spec: RequestSpec, as type: T.Type) async throws -> T {
        let data = try await executeWithRetry(spec)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FocttaError.api(
                status: 200,
                problemDetail: nil,
                message: "Failed to decode \(T.self): \(error.localizedDescription)"
            )
        }
    }

    /// Execute a request with no expected response body.
    func requestEmpty(_ spec: RequestSpec) async throws {
        _ = try await executeWithRetry(spec)
    }

    private func executeWithRetry(_ spec: RequestSpec) async throws -> Data {
        var attempt = 0
        var lastError: FocttaError?

        while attempt <= configuration.maxRetries {
            do {
                return try await sendOnce(spec)
            } catch let err as FocttaError {
                switch err {
                case .api:
                    // 4xx (not 429) — non-retryable. Propagate immediately.
                    throw err
                case .server, .network:
                    lastError = err
                default:
                    throw err
                }
            }
            attempt += 1
            if attempt <= configuration.maxRetries {
                let delay = retryDelaySeconds(attempt: attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? FocttaError.network(
            attemptCount: attempt,
            message: "Exhausted retries without a typed failure.",
            underlying: nil
        )
    }

    private func sendOnce(_ spec: RequestSpec) async throws -> Data {
        guard let url = URL(string: buildURL(spec)) else {
            throw FocttaError.validation(message: "Bad URL: \(buildURL(spec))")
        }
        var req = URLRequest(url: url)
        req.httpMethod = spec.method.rawValue
        // v1.0 auth model: slug-routed public endpoints, NO X-API-Key
        // header. The tenantSlug is in the URL path; tenantId is in
        // request bodies. Backend rate-limits handle abuse.
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if let body = spec.body {
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let key = spec.idempotencyKey {
            req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        for (k, v) in spec.headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw FocttaError.network(
                attemptCount: -1,
                message: "Network error: \(error.localizedDescription)",
                underlying: error
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw FocttaError.network(
                attemptCount: -1,
                message: "Non-HTTP response",
                underlying: nil
            )
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 429, 500..<600:
            throw FocttaError.server(
                status: http.statusCode,
                attemptCount: -1,
                message: "Retryable failure \(http.statusCode) on \(spec.method.rawValue) \(spec.path)"
            )
        default:
            let problem = try? decoder.decode(ProblemDetail.self, from: data)
            throw FocttaError.api(
                status: http.statusCode,
                problemDetail: problem,
                message: problem?.detail ?? problem?.title
                    ?? "API error \(http.statusCode) on \(spec.method.rawValue) \(spec.path)"
            )
        }
    }

    private func buildURL(_ spec: RequestSpec) -> String {
        let base = configuration.resolvedBaseURL
        return spec.path.hasPrefix("/") ? "\(base)\(spec.path)" : "\(base)/\(spec.path)"
    }

    private func retryDelaySeconds(attempt: Int) -> Double {
        switch attempt {
        case 1: return 1
        case 2: return 2
        default: return 4
        }
    }
}
