//
//  AuthenticationInterceptorTests.swift
//
//  Copyright (c) 2020 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

@testable import Alamofire
import Foundation
import XCTest

class AuthenticationInterceptorTestCase: BaseTestCase {

    // MARK: - Helper Types

    struct OAuthCredential: AuthenticationCredential {
        let accessToken: String
        let refreshToken: String
        let userID: String
        let expiration: Date

        let requiresRefresh: Bool

        init(
            accessToken: String = "a0",
            refreshToken: String = "r0",
            userID: String = "u0",
            expiration: Date = Date(),
            requiresRefresh: Bool = false)
        {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.userID = userID
            self.expiration = expiration
            self.requiresRefresh = requiresRefresh
        }
    }

    enum OAuthError: Error {
        case refreshNetworkFailure
    }

    class OAuthAuthenticator: Authenticator {
        private(set) var applyCount = 0
        private(set) var refreshCount = 0
        private(set) var didRequestFailDueToAuthErrorCount = 0
        private(set) var isRequestAuthenticatedWithCredentialCount = 0

        let refreshResult: Result<OAuthCredential, Error>?
        let lock = NSLock()

        init(refreshResult: Result<OAuthCredential, Error>? = nil) {
            self.refreshResult = refreshResult
        }

        func apply(_ credential: OAuthCredential, to urlRequest: inout URLRequest) {
            lock.lock() ; defer { lock.unlock() }

            applyCount += 1

            let authorization = HTTPHeader.authorization(bearerToken: credential.accessToken)
            urlRequest.addValue(authorization.value, forHTTPHeaderField: authorization.name)
        }

        func refresh(_ credential: OAuthCredential, completion: @escaping (Result<OAuthCredential, Error>) -> Void) {
            lock.lock() ; defer { lock.unlock() }

            refreshCount += 1

            let refreshResult = self.refreshResult ?? .success(
                OAuthCredential(
                    accessToken: "a\(refreshCount)",
                    refreshToken: "a\(refreshCount)",
                    userID: "u1",
                    expiration: Date()
                )
            )

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { completion(refreshResult) }
        }

        func didRequest(_ urlRequest: URLRequest, with response: HTTPURLResponse, failDueToAuthenticationError error: Error) -> Bool {
            lock.lock() ; defer { lock.unlock() }

            didRequestFailDueToAuthErrorCount += 1

            return response.statusCode == 401
        }

        func isRequest(_ urlRequest: URLRequest, authenticatedWith credential: OAuthCredential) -> Bool {
            lock.lock() ; defer { lock.unlock() }

            isRequestAuthenticatedWithCredentialCount += 1

            let bearerToken = HTTPHeader.authorization(bearerToken: credential.accessToken).value

            return urlRequest.value(forHTTPHeaderField: "Authorization") == bearerToken
        }
    }

    class PathAdapter: RequestAdapter {
        var paths: [String]

        init(paths: [String]) {
            self.paths = paths
        }

        func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping (Result<URLRequest, Error>) -> Void) {
            var request = urlRequest

            var urlComponents = URLComponents(string: request.url!.absoluteString)!
            urlComponents.path = paths.removeFirst()

            request.url = urlComponents.url

            DispatchQueue.main.async { completion(.success(request)) }
        }
    }

    // MARK: - Tests - Adapt

    func testThatInterceptorCanAdaptURLRequest() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let urlRequest = URLRequest.makeHTTPBinRequest()
        let session = Session()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a0")
        XCTAssertEqual(response?.result.isSuccess, true)

        XCTAssertEqual(authenticator.applyCount, 1)
        XCTAssertEqual(authenticator.refreshCount, 0)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 0)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 0)

        XCTAssertEqual(request.retryCount, 0)
    }

    func testThatInterceptorQueuesAdaptOperationWhenRefreshing() {
        // Given
        let credential = OAuthCredential(requiresRefresh: true)
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let urlRequest1 = URLRequest.makeHTTPBinRequest(path: "/status/200")
        let urlRequest2 = URLRequest.makeHTTPBinRequest(path: "/status/202")
        let session = Session()

        let expect = expectation(description: "both requests should complete")
        expect.expectedFulfillmentCount = 2

        var response1: AFDataResponse<Data?>?
        var response2: AFDataResponse<Data?>?

        // When
        let request1 = session.request(urlRequest1, interceptor: interceptor).validate().response {
            response1 = $0
            expect.fulfill()
        }

        let request2 = session.request(urlRequest2, interceptor: interceptor).validate().response {
            response2 = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response1?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a1")
        XCTAssertEqual(response2?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a1")
        XCTAssertEqual(response1?.result.isSuccess, true)
        XCTAssertEqual(response2?.result.isSuccess, true)

        XCTAssertEqual(authenticator.applyCount, 2)
        XCTAssertEqual(authenticator.refreshCount, 1)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 0)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 0)

        XCTAssertEqual(request1.retryCount, 0)
        XCTAssertEqual(request2.retryCount, 0)
    }

    func testThatInterceptorThrowsMissingCredentialErrorWhenCredentialIsNil() {
        // Given
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator)

        let urlRequest = URLRequest.makeHTTPBinRequest()
        let session = Session()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.headers.count, 0)

        XCTAssertEqual(response?.result.isFailure, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.isRequestAdaptationError, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.underlyingError as? AuthenticationError, .missingCredential)

        XCTAssertEqual(authenticator.applyCount, 0)
        XCTAssertEqual(authenticator.refreshCount, 0)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 0)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 0)

        XCTAssertEqual(request.retryCount, 0)
    }

    func testThatInterceptorRethrowsRefreshErrorFromAdapt() {
        // Given
        let credential = OAuthCredential(requiresRefresh: true)
        let authenticator = OAuthAuthenticator(refreshResult: .failure(OAuthError.refreshNetworkFailure))
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let session = Session()
        let urlRequest = URLRequest.makeHTTPBinRequest()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.headers.count, 0)

        XCTAssertEqual(response?.result.isFailure, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.isRequestAdaptationError, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.underlyingError as? OAuthError, .refreshNetworkFailure)

        if case .requestRetryFailed(_, let originalError) = response?.result.failure {
            XCTAssertEqual(originalError.asAFError?.isResponseValidationError, true)
            XCTAssertEqual(originalError.asAFError?.responseCode, 401)
        }

        XCTAssertEqual(authenticator.applyCount, 0)
        XCTAssertEqual(authenticator.refreshCount, 1)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 0)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 0)

        XCTAssertEqual(request.retryCount, 0)
    }

    // MARK: - Tests - Retry

    func testThatInterceptorDoesNotRetryWithoutResponse() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let urlRequest = URLRequest(url: URL(string: "/invalid/path")!)
        let session = Session()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a0")

        XCTAssertEqual(response?.result.isFailure, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.isSessionTaskError, true)

        XCTAssertEqual(authenticator.applyCount, 1)
        XCTAssertEqual(authenticator.refreshCount, 0)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 0)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 0)

        XCTAssertEqual(request.retryCount, 0)
    }

    func testThatInterceptorDoesNotRetryWhenRequestDoesNotFailDueToAuthError() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let urlRequest = URLRequest.makeHTTPBinRequest(path: "status/500")
        let session = Session()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a0")

        XCTAssertEqual(response?.result.isFailure, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.isResponseValidationError, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.responseCode, 500)

        XCTAssertEqual(authenticator.applyCount, 1)
        XCTAssertEqual(authenticator.refreshCount, 0)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 1)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 0)

        XCTAssertEqual(request.retryCount, 0)
    }

    func testThatInterceptorThrowsMissingCredentialErrorWhenCredentialIsNilAndRequestShouldBeRetried() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let eventMonitor = ClosureEventMonitor()
        eventMonitor.requestDidCreateTask = { _, _ in interceptor.credential = nil }

        let session = Session(eventMonitors: [eventMonitor])

        let urlRequest = URLRequest.makeHTTPBinRequest(path: "status/401")

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a0")

        XCTAssertEqual(response?.result.isFailure, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.isRequestRetryError, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.underlyingError as? AuthenticationError, .missingCredential)

        if case .requestRetryFailed(_, let originalError) = response?.result.failure {
            XCTAssertEqual(originalError.asAFError?.isResponseValidationError, true)
            XCTAssertEqual(originalError.asAFError?.responseCode, 401)
        }

        XCTAssertEqual(authenticator.applyCount, 1)
        XCTAssertEqual(authenticator.refreshCount, 0)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 1)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 0)

        XCTAssertEqual(request.retryCount, 0)
    }

    func testThatInterceptorRetriesRequestThatFailedWithOutdatedCredential() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let eventMonitor = ClosureEventMonitor()

        eventMonitor.requestDidCreateTask = { _, _ in
            interceptor.credential = OAuthCredential(
                accessToken: "a1",
                refreshToken: "r1",
                userID: "u0",
                expiration: Date(),
                requiresRefresh: false
            )
        }

        let session = Session(eventMonitors: [eventMonitor])

        let pathAdapter = PathAdapter(paths: ["/status/401", "/status/200"])
        let compositeInterceptor = Interceptor(adapters: [pathAdapter, interceptor], retriers: [interceptor])

        let urlRequest = URLRequest.makeHTTPBinRequest()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: compositeInterceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a1")
        XCTAssertEqual(response?.result.isSuccess, true)

        XCTAssertEqual(authenticator.applyCount, 2)
        XCTAssertEqual(authenticator.refreshCount, 0)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 1)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 1)

        XCTAssertEqual(request.retryCount, 1)
    }

    func testThatInterceptorRetriesRequestAfterRefresh() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let pathAdapter = PathAdapter(paths: ["/status/401", "/status/200"])

        let compositeInterceptor = Interceptor(adapters: [pathAdapter, interceptor], retriers: [interceptor])

        let session = Session()
        let urlRequest = URLRequest.makeHTTPBinRequest()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: compositeInterceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a1")
        XCTAssertEqual(response?.result.isSuccess, true)

        XCTAssertEqual(authenticator.applyCount, 2)
        XCTAssertEqual(authenticator.refreshCount, 1)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 1)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 1)

        XCTAssertEqual(request.retryCount, 1)
    }

    func testThatInterceptorRethrowsRefreshErrorFromRetry() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator(refreshResult: .failure(OAuthError.refreshNetworkFailure))
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let session = Session()
        let urlRequest = URLRequest.makeHTTPBinRequest(path: "/status/401")

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a0")

        XCTAssertEqual(response?.result.isFailure, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.isRequestRetryError, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.underlyingError as? OAuthError, .refreshNetworkFailure)

        if case .requestRetryFailed(_, let originalError) = response?.result.failure {
            XCTAssertEqual(originalError.asAFError?.isResponseValidationError, true)
            XCTAssertEqual(originalError.asAFError?.responseCode, 401)
        }

        XCTAssertEqual(authenticator.applyCount, 1)
        XCTAssertEqual(authenticator.refreshCount, 1)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 1)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 1)

        XCTAssertEqual(request.retryCount, 0)
    }

    func testThatInterceptorMultipleRequestsInParallelTrippingRefreshThroughRetry() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let requestCount = 6
        let urlRequest = URLRequest.makeHTTPBinRequest()
        let session = Session()

        let expect = expectation(description: "both requests should complete")
        expect.expectedFulfillmentCount = requestCount

        var requests: [Int: Request] = [:]
        var responses: [Int: AFDataResponse<Data?>] = [:]

        for index in 0..<requestCount {
            let pathAdapter = PathAdapter(paths: ["/status/401", "/status/20\(index)"])
            let compositeInterceptor = Interceptor(adapters: [pathAdapter, interceptor], retriers: [interceptor])

            // When
            let request = session.request(urlRequest, interceptor: compositeInterceptor).validate().response {
                responses[index] = $0
                expect.fulfill()
            }

            requests[index] = request
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        for index in 0..<requestCount {
            let response = responses[index]
            XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a1")
            XCTAssertEqual(response?.result.isSuccess, true)

            let request = requests[index]
            XCTAssertEqual(request?.retryCount, 1)
        }

        XCTAssertEqual(authenticator.applyCount, 12)
        XCTAssertEqual(authenticator.refreshCount, 1)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 6)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 6)
    }

    // MARK: - Tests - Excessive Refresh

    func testThatInterceptorIgnoresExcessiveRefreshWhenRefreshWindowIsNil() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(authenticator: authenticator, credential: credential)

        let pathAdapter = PathAdapter(paths: [
            "/status/401",
            "/status/401",
            "/status/401",
            "/status/401",
            "/status/401",
            "/status/200"
        ])

        let compositeInterceptor = Interceptor(adapters: [pathAdapter, interceptor], retriers: [interceptor])

        let session = Session()
        let urlRequest = URLRequest.makeHTTPBinRequest()

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: compositeInterceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a5")
        XCTAssertEqual(response?.result.isSuccess, true)

        XCTAssertEqual(authenticator.applyCount, 6)
        XCTAssertEqual(authenticator.refreshCount, 5)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 5)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 5)

        XCTAssertEqual(request.retryCount, 5)
    }

    func testThatInterceptorThrowsExcessiveRefreshErrorWhenExcessiveRefreshOccurs() {
        // Given
        let credential = OAuthCredential()
        let authenticator = OAuthAuthenticator()
        let interceptor = AuthenticationInterceptor(
            authenticator: authenticator,
            credential: credential,
            refreshWindow: .init(interval: 30, maximumAttempts: 2)
        )

        let session = Session()
        let urlRequest = URLRequest.makeHTTPBinRequest(path: "/status/401")

        let expect = expectation(description: "request should complete")
        var response: AFDataResponse<Data?>?

        // When
        let request = session.request(urlRequest, interceptor: interceptor).validate().response {
            response = $0
            expect.fulfill()
        }

        waitForExpectations(timeout: timeout, handler: nil)

        // Then
        XCTAssertEqual(response?.request?.value(forHTTPHeaderField: "Authorization"), "Bearer a2")

        XCTAssertEqual(response?.result.isFailure, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.isRequestRetryError, true)
        XCTAssertEqual(response?.result.failure?.asAFError?.underlyingError as? AuthenticationError, .excessiveRefresh)

        if case .requestRetryFailed(_, let originalError) = response?.result.failure {
            XCTAssertEqual(originalError.asAFError?.isResponseValidationError, true)
            XCTAssertEqual(originalError.asAFError?.responseCode, 401)
        }

        XCTAssertEqual(authenticator.applyCount, 3)
        XCTAssertEqual(authenticator.refreshCount, 2)
        XCTAssertEqual(authenticator.didRequestFailDueToAuthErrorCount, 3)
        XCTAssertEqual(authenticator.isRequestAuthenticatedWithCredentialCount, 3)

        XCTAssertEqual(request.retryCount, 2)
    }
}
