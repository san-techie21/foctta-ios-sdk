// APIClientTests.swift — wire-layer tests using URLProtocol mocks.
//
// v1.0 — slug-routed public endpoints, no X-API-Key header.

import XCTest
@testable import FOCTTA

final class ConfigurationTests: XCTestCase {

    private let validTenant = "00000000-0000-4000-9100-000000000001"

    func testValidConfigurationResolvesBaseURL() throws {
        let c = Configuration(
            tenantSlug: "motilal-oswal",
            tenantId: validTenant,
            environment: .production
        )
        try c.validate()
        XCTAssertEqual(c.resolvedBaseURL, "https://app.foctta.com/v1")
    }

    func testExplicitBaseURLOverrides() throws {
        let c = Configuration(
            tenantSlug: "motilal-oswal",
            tenantId: validTenant,
            baseURL: "https://motilal-oswal.foctta.com/v1/"
        )
        try c.validate()
        XCTAssertEqual(c.resolvedBaseURL, "https://motilal-oswal.foctta.com/v1")
    }

    func testAcceptsValidTenantSlugs() throws {
        for slug in ["motilal-oswal", "apex", "acme-financial", "hdfc-bank-01"] {
            try Configuration(tenantSlug: slug, tenantId: validTenant).validate()
        }
    }

    func testRejectsEmptySlug() {
        let c = Configuration(tenantSlug: "", tenantId: validTenant)
        XCTAssertThrowsError(try c.validate()) { error in
            guard case FocttaError.validation(let msg) = error else {
                return XCTFail("Expected .validation")
            }
            XCTAssertTrue(msg.contains("tenantSlug"))
        }
    }

    func testRejectsSlugWithUppercaseOrInvalidChars() {
        for bad in ["Motilal-Oswal", "motilal_oswal", "motilal.oswal", "motilal oswal"] {
            let c = Configuration(tenantSlug: bad, tenantId: validTenant)
            XCTAssertThrowsError(try c.validate(), "slug '\(bad)' should be rejected")
        }
    }

    func testRejectsHTTPBaseURL() {
        let c = Configuration(
            tenantSlug: "motilal-oswal",
            tenantId: validTenant,
            baseURL: "http://insecure.example.com/v1"
        )
        XCTAssertThrowsError(try c.validate())
    }

    func testRejectsMalformedTenantID() {
        let c = Configuration(tenantSlug: "motilal-oswal", tenantId: "not-a-uuid")
        XCTAssertThrowsError(try c.validate())
    }
}

// MARK: - APIClient — URLProtocol mocking

final class APIClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.responses.removeAll()
        MockURLProtocol.requestCount = 0
        MockURLProtocol.lastHeaders.removeAll()
    }

    override func tearDown() {
        MockURLProtocol.responses.removeAll()
        super.tearDown()
    }

    private func makeClient(maxRetries: Int = 2) -> APIClient {
        let config = Configuration(
            tenantSlug: "motilal-oswal",
            tenantId: "00000000-0000-4000-9100-000000000001",
            environment: .staging,
            baseURL: "https://api.test.local/v1",
            timeoutSeconds: 2,
            maxRetries: maxRetries
        )
        let session = mockSession()
        return APIClient(configuration: config, session: session)
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testSuccessDecodesEnvelope() async throws {
        MockURLProtocol.responses.append(.init(
            status: 201,
            headers: ["Content-Type": "application/json"],
            body: sampleRecordResponse.data(using: .utf8)!
        ))
        let client = makeClient()
        let envelope: RecordConsentLogEnvelope = try await client.request(
            RequestSpec(method: .POST, path: "/cookie-consent-logs", body: Data("{}".utf8), idempotencyKey: "k1"),
            as: RecordConsentLogEnvelope.self
        )
        XCTAssertEqual(envelope.data.id, "log_abc123")
        XCTAssertEqual(envelope.receipt.receiptId, "rec_xyz789")
        XCTAssertEqual(envelope.receipt.chainPosition, 847)
    }

    func test4xxSurfacesAPIErrorWithProblemDetail() async {
        let problem = """
        {"type":"about:blank","title":"Validation","status":400,"detail":"domain is required"}
        """
        MockURLProtocol.responses.append(.init(
            status: 400,
            headers: ["Content-Type": "application/problem+json"],
            body: problem.data(using: .utf8)!
        ))
        let client = makeClient()
        do {
            let _: RecordConsentLogEnvelope = try await client.request(
                RequestSpec(method: .POST, path: "/cookie-consent-logs", body: Data("{}".utf8), idempotencyKey: "k2"),
                as: RecordConsentLogEnvelope.self
            )
            XCTFail("Expected throw")
        } catch let FocttaError.api(status, detail, message) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail?.title, "Validation")
            XCTAssertTrue(message.contains("domain"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test5xxRetriesThenSucceeds() async throws {
        MockURLProtocol.responses.append(.init(status: 503, headers: [:], body: Data()))
        MockURLProtocol.responses.append(.init(status: 503, headers: [:], body: Data()))
        MockURLProtocol.responses.append(.init(
            status: 201,
            headers: ["Content-Type": "application/json"],
            body: sampleRecordResponse.data(using: .utf8)!
        ))
        let client = makeClient()
        let envelope: RecordConsentLogEnvelope = try await client.request(
            RequestSpec(method: .POST, path: "/cookie-consent-logs", body: Data("{}".utf8), idempotencyKey: "k3"),
            as: RecordConsentLogEnvelope.self
        )
        XCTAssertEqual(envelope.data.id, "log_abc123")
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testNoXAPIKeyHeaderInV1() async throws {
        // CRITICAL: v1.0 slug-routed public endpoints — NEVER an
        // X-API-Key header on the wire. The tenantSlug is in the URL
        // path; tenantId is in the request body.
        MockURLProtocol.responses.append(.init(
            status: 201,
            headers: ["Content-Type": "application/json"],
            body: sampleRecordResponse.data(using: .utf8)!
        ))
        let client = makeClient()
        let _: RecordConsentLogEnvelope = try await client.request(
            RequestSpec(method: .POST, path: "/cookie-consent-logs", body: Data("{}".utf8), idempotencyKey: "k5"),
            as: RecordConsentLogEnvelope.self
        )
        XCTAssertNil(MockURLProtocol.lastHeaders["X-API-Key"])
        XCTAssertNil(MockURLProtocol.lastHeaders["X-Tenant-ID"])
        XCTAssertNil(MockURLProtocol.lastHeaders["Authorization"])
        // But idempotency + user-agent + accept ARE sent
        XCTAssertEqual(MockURLProtocol.lastHeaders["Idempotency-Key"], "k5")
        XCTAssertTrue(MockURLProtocol.lastHeaders["User-Agent"]?.contains("foctta-ios-sdk/") ?? false)
        XCTAssertEqual(MockURLProtocol.lastHeaders["Accept"], "application/json")
    }

    private let sampleRecordResponse = """
    {
      "data": {
        "id": "log_abc123",
        "tenantId": "00000000-0000-4000-9100-000000000001",
        "domain": "motilaloswalmf.com",
        "visitorId": "visitor-test",
        "consentAction": "accept_all",
        "categoriesAccepted": ["analytics", "marketing"],
        "categoriesRejected": [],
        "regulation": "DPDPA",
        "createdAt": "2026-05-27T07:00:00Z"
      },
      "receipt": {
        "receiptId": "rec_xyz789",
        "eventType": "consent.recorded",
        "eventHash": "sha256:abcdef",
        "previousHash": null,
        "chainPosition": 847,
        "signature": "hmac:xyz",
        "timestamp": "2026-05-27T07:00:00Z"
      }
    }
    """
}

// MARK: - Receipt validation

final class AuditServiceCryptoTests: XCTestCase {

    func testValidateRecomputesHash() {
        let store = ReceiptStore()
        let apiClient = APIClient(configuration: Configuration(
            tenantSlug: "motilal-oswal",
            tenantId: "00000000-0000-4000-9100-000000000001"
        ))
        let service = AuditService(apiClient: apiClient, receiptStore: store)

        // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let payload = Data("hello".utf8)
        let receipt = StoredReceipt(
            receiptId: "rec_t1",
            eventType: "consent.recorded",
            entityId: "log_t1",
            chainPosition: 1,
            eventHash: "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            previousHash: nil,
            signature: "x",
            timestamp: "2026-05-27T07:00:00Z"
        )
        let result = service.validate(receipt, canonicalPayload: payload)
        XCTAssertEqual(result, .valid)
    }
}

// MARK: - URLProtocol mock

private final class MockURLProtocol: URLProtocol {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let resp = Self.responses.removeFirst()
        let url = request.url ?? URL(string: "https://api.test.local")!
        let httpResp = HTTPURLResponse(
            url: url,
            statusCode: resp.status,
            httpVersion: "HTTP/1.1",
            headerFields: resp.headers
        )!
        client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resp.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
