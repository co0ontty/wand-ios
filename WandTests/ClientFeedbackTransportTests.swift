import Foundation
import XCTest
@testable import Wand

private final class FeedbackURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not collected".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClientFeedbackTransportTests: XCTestCase {
    func testFeedbackDelegateRejectsSameAndCrossOriginRedirectsWithoutChangingBusinessRequests() {
        let base = URL(string: "https://redirect-test.example/prefix")!
        let endpoint = SelfSignedSession.forEndpoint(base)
        defer { SelfSignedSession.resetEndpoint(base) }
        let feedback = endpoint.session.dataTask(with: URL(string: "https://redirect-test.example/prefix/api/feedback/client")!)
        let business = endpoint.session.dataTask(with: URL(string: "https://redirect-test.example/prefix/api/sessions")!)
        for target in ["https://redirect-test.example/prefix/other", "https://another-origin.example/leak"] {
            let request = URLRequest(url: URL(string: target)!)
            let response = HTTPURLResponse(url: feedback.originalRequest!.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": target])!
            let rejected = expectation(description: "redirect rejected")
            endpoint.urlSession(endpoint.session, task: feedback, willPerformHTTPRedirection: response, newRequest: request) { redirected in
                XCTAssertNil(redirected)
                rejected.fulfill()
            }
            wait(for: [rejected], timeout: 1)
        }
        let allowed = URLRequest(url: URL(string: "https://redirect-test.example/prefix/api/session-list")!)
        let response = HTTPURLResponse(url: business.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        endpoint.urlSession(endpoint.session, task: business, willPerformHTTPRedirection: response, newRequest: allowed) { redirected in
            XCTAssertEqual(redirected?.url, allowed.url)
        }
    }

    func testFeedbackResponseIsCancelledAtHeadersButBusinessBodyRemainsAllowed() {
        let base = URL(string: "https://body-test.example")!
        let endpoint = SelfSignedSession.forEndpoint(base)
        defer { SelfSignedSession.resetEndpoint(base) }
        for (path, expected) in [("/api/feedback/client", URLSession.ResponseDisposition.cancel), ("/api/sessions", .allow)] {
            let url = base.appendingPathComponent(path)
            let task = endpoint.session.dataTask(with: url)
            let response = HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: ["Content-Length": "999999999"])!
            let checked = expectation(description: path)
            endpoint.urlSession(endpoint.session, dataTask: task, didReceive: response) { disposition in
                XCTAssertEqual(disposition, expected)
                checked.fulfill()
            }
            wait(for: [checked], timeout: 1)
        }
    }

    func testHTTP5xxSendsAuthenticatedRedactedSchemaOnceAndNeverReportsResponseBody() throws {
        let base = URL(string: "https://transport-test.example/prefix")!
        let api = WandAPI(baseURL: base, token: "private-app-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackURLProtocol.self]
        api.endpointSession.session = URLSession(configuration: configuration, delegate: api.endpointSession, delegateQueue: nil)
        defer { FeedbackURLProtocol.handler = nil; SelfSignedSession.resetEndpoint(base) }
        let sent = expectation(description: "feedback send")
        sent.assertForOverFulfill = true
        FeedbackURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://transport-test.example/prefix/api/feedback/client")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-app-token")
            XCTAssertEqual(request.timeoutInterval, 5)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("private-app-token"))
            XCTAssertFalse(text.contains("PRIVATE RESPONSE BODY"))
            let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(report?["source"] as? String, "ios")
            XCTAssertEqual(report?["event"] as? String, "http_5xx")
            XCTAssertEqual(report?["feature"] as? String, "tasks")
            XCTAssertNil(report?["username"])
            XCTAssertTrue(text.contains("Original failure"))
            sent.fulfill()
        }
        let data = Data(#"{"error":"Original failure private-app-token","body":"PRIVATE RESPONSE BODY"}"#.utf8)
        api.reportHTTPFailure(status: 503, data: data, path: "/api/wand-tasks/private-id/comments")
        api.reportHTTPFailure(status: 503, data: data, path: "/api/wand-tasks/private-id/comments")
        api.reportHTTPFailure(status: 503, data: data, path: "/api/feedback/client")
        api.reportHTTPFailure(status: 400, data: data, path: "/api/wand-tasks/private-id/comments")
        wait(for: [sent], timeout: 2)
    }
}
