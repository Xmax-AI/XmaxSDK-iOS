import Foundation
import XCTest
@testable import XmaxSDK

final class XmaxClientCreditBalanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CreditBalanceURLProtocol.state.reset()
    }

    func testQueryUsesGeneralEnvironmentAPIKeyAndGetWithoutBody() async throws {
        for environment in XmaxEnvironment.allCases {
            let client = makeClient(key: "  balance-key\n", environment: environment)
            CreditBalanceURLProtocol.state.respond(
                #"{"success":true,"data":{"currentBalance":1250.75}}"#
            )
            let balance = try await client.getCreditBalance()
            XCTAssertEqual(balance.currentBalance, 1250.75)
            let request = try XCTUnwrap(CreditBalanceURLProtocol.state.requests.last)
            XCTAssertEqual(
                request.url?.absoluteString,
                environment == .china
                    ? "https://cloud.xmax.22duck.cn/open/api/v1/balance"
                    : "https://api.xmax.cloud/open/api/v1/balance"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "balance-key")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertNil(request.httpBody)
        }
    }

    func testEveryCallFetchesFreshBalanceAndPreservesZeroAndFractions() async throws {
        let client = makeClient()
        for value in [0.0, 0.25, 1250.75] {
            CreditBalanceURLProtocol.state.respond(
                "{\"success\":true,\"data\":{\"currentBalance\":\(value)}}"
            )
            let balance = try await client.getCreditBalance()
            XCTAssertEqual(balance.currentBalance, value)
        }
        XCTAssertEqual(CreditBalanceURLProtocol.state.requests.count, 3)
    }

    func testEmptyKeyFailsBeforeNetworkRequest() async {
        do {
            _ = try await makeClient(key: " \n ").getCreditBalance()
            XCTFail("Expected invalid key")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidAPIKey) }
        XCTAssertTrue(CreditBalanceURLProtocol.state.requests.isEmpty)
    }

    func testMalformedMissingNegativeAndNonfiniteBalanceNeverBecomeZero() async {
        for payload in [
            "null", "[]", "{}", #"{"currentBalance":null}"#,
            #"{"currentBalance":true}"#, #"{"currentBalance":"1250.75"}"#,
            #"{"currentBalance":-1}"#, #"{"currentBalance":1e400}"#,
            #"{"currentBalance":[]}"#, #"{"currentBalance":{}}"#
        ] {
            CreditBalanceURLProtocol.state.respond("{\"success\":true,\"data\":\(payload)}")
            do {
                _ = try await makeClient().getCreditBalance()
                XCTFail("Expected invalid balance: \(payload)")
            } catch { XCTAssertEqual((error as? XmaxError)?.code, .apiError, payload) }
        }
    }

    func testBusinessErrorPreservesServerAndHTTPStatus() async {
        CreditBalanceURLProtocol.state.respond(
            #"{"success":false,"code":1007,"message":"Access denied"}"#,
            status: 403
        )
        do {
            _ = try await makeClient().getCreditBalance()
            XCTFail("Expected business error")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(code: .apiError, message: "Access denied", apiCode: 1007, httpStatus: 403)
            )
        }
    }

    func testTransportCancellationRemainsCancelled() async {
        CreditBalanceURLProtocol.state.respond(error: URLError(.cancelled))
        do {
            _ = try await makeClient().getCreditBalance()
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
    }

    private func makeClient(key: String = "balance-key", environment: XmaxEnvironment = .china)
        -> XmaxClient
    {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [CreditBalanceURLProtocol.self]
        return XmaxClient(
            configuration: XmaxConfiguration(apiKey: key, environment: environment),
            session: URLSession(configuration: settings)
        )
    }
}

private final class CreditBalanceURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = CreditBalanceHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.capture(request)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CreditBalanceHTTPState: @unchecked Sendable {
    struct Response {
        var status = 200
        var data = Data()
        var error: (any Error)?
    }
    private let lock = NSLock()
    private var response = Response()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    func reset() {
        lock.withLock {
            response = Response()
            captured.removeAll()
        }
    }
    func respond(_ json: String = "", status: Int = 200, error: (any Error)? = nil) {
        lock.withLock { response = Response(status: status, data: Data(json.utf8), error: error) }
    }
    func capture(_ request: URLRequest) -> Response {
        lock.withLock {
            captured.append(request)
            return response
        }
    }
}
