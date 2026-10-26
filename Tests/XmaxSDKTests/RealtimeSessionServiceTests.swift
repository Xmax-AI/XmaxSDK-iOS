//
//  RealtimeSessionServiceTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

final class RealtimeSessionServiceTests: XCTestCase {
    func testCreateSessionUsesPublicModelIdentifiers() async throws {
        XCTAssertEqual(
            RealtimeModel.allCases.map(\.rawValue),
            ["x2.1"]
        )
        for model in RealtimeModel.allCases {
            let payload = try JSONSerialization.data(withJSONObject: [
                "sessionUid": "session", "userUid": "user",
                "modelExtra": [
                    "room_id": "room", "room_token": "token", "rtc_user_id": "rtc-user",
                    "rtc_bot_id": "bot", "rtc_app_id": RtcEngineManager.defaultAppID
                ]
            ])
            let api = RealtimeApiServiceStub(responses: [.success(payload)])
            _ = try await RealtimeSessionService(apiService: api).createSession(model: model)
            let body = try XCTUnwrap(api.requests.first?.body)
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: body) as? [String: String],
                ["model": model.rawValue]
            )
        }
    }

    func testInvalidAgoraAppIDClosesCreatedSessionAndPreservesOriginalError() async throws {
        let payload = Data(#"{"sessionUid":"invalid-app","userUid":"user","modelExtra":{"room_id":"room","room_token":"token","rtc_user_id":"account","rtc_bot_id":"bot","rtc_app_id":"other-app"}}"#.utf8)
        let api = RealtimeApiServiceStub(responses: [.success(payload), .success(Data("{}".utf8))])
        let service = RealtimeSessionService(apiService: api)
        do {
            _ = try await service.createSession(model: .x2_1)
            XCTFail("Expected invalid Agora app ID")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .sessionError)
        }
        XCTAssertEqual(api.requests.map(\.path), ["/session", "/session/invalid-app"])
        XCTAssertEqual(api.requests.last?.method, .delete)
    }

    func testMissingRTCAccountDoesNotFallBackToBusinessUserID() async throws {
        let payload = Data(#"{"sessionUid":"missing-account","userUid":"business-user","modelExtra":{"room_id":"room","room_token":"token","rtc_bot_id":"bot","rtc_app_id":"5588dfe2e7874bd08ea28f4968ec2d40"}}"#.utf8)
        let api = RealtimeApiServiceStub(responses: [.success(payload), .success(Data("{}".utf8))])
        do {
            _ = try await RealtimeSessionService(apiService: api).createSession(model: .x2_1)
            XCTFail("Expected missing RTC account")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .sessionError)
        }
        XCTAssertEqual(api.requests.last?.path, "/session/missing-account")
    }

    func testCreateSessionParsesObjectConnectionAndNormalizesValues() async throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "sessionUid": " session-1 ",
                "userUid": " user-1 ",
                "status": " ACTIVE ",
                "modelExtra": [
                    "room_id": " room-1 ",
                    "room_token": " token-1 ",
                    "rtc_user_id": " rtc-user-1 ",
                    "rtc_bot_id": " bot-1 ",
                    "rtc_app_id": RtcEngineManager.defaultAppID
                ]
            ]
        )
        let apiService = RealtimeApiServiceStub(
            responses: [.success(payload)]
        )
        let service = RealtimeSessionService(apiService: apiService)

        let session = try await service.createSession(model: .x2_1)

        XCTAssertEqual(
            session,
            RealtimeSession(
                id: "session-1",
                userID: "user-1",
                status: "ACTIVE",
                connection: RealtimeSessionConnection(
                    roomID: "room-1",
                    userID: "rtc-user-1",
                    token: "token-1",
                    botName: "bot-1"
                ),
                closeReason: nil
            )
        )
        let request = try XCTUnwrap(apiService.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/session")
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: body) as? [String: String],
            ["model": "x2.1"]
        )
    }

    func testCreateSessionParsesJSONStringWithSeparateRTCAccount() async throws {
        let modelExtra = #"{"room_id":"room-2","room_token":"token-2","rtc_user_id":"rtc-user-2","rtc_bot_id":"bot-2","rtc_app_id":"5588dfe2e7874bd08ea28f4968ec2d40"}"#
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "sessionUid": "session-2",
                "userUid": "user-2",
                "modelExtra": modelExtra
            ]
        )
        let apiService = RealtimeApiServiceStub(
            responses: [.success(payload)]
        )
        let service = RealtimeSessionService(apiService: apiService)

        let session = try await service.createSession(model: .x2_1)

        XCTAssertEqual(
            session.connection,
            RealtimeSessionConnection(
                roomID: "room-2",
                userID: "rtc-user-2",
                token: "token-2",
                botName: "bot-2"
            )
        )
    }

    func testCreateSessionRejectsMissingIdentifier() async {
        let apiService = RealtimeApiServiceStub(
            responses: [.success(Data(#"{"modelExtra":{}}"#.utf8))]
        )
        let service = RealtimeSessionService(apiService: apiService)

        do {
            _ = try await service.createSession(model: .x2_1)
            XCTFail("Expected invalid session data to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .sessionError,
                    message: "Invalid session response"
                )
            )
        }
    }

    func testCreateSessionRejectsIncompleteConnection() async {
        let apiService = RealtimeApiServiceStub(
            responses: [
                .success(
                    Data(
                        #"{"sessionUid":"session-3","modelExtra":{"room_id":"room-3"}}"#.utf8
                    )
                )
            ]
        )
        let service = RealtimeSessionService(apiService: apiService)

        do {
            _ = try await service.createSession(model: .x2_1)
            XCTFail("Expected incomplete RTC information to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .sessionError,
                    message: "Session does not contain complete RTC join information"
                )
            )
        }
    }

    func testCloseSessionUsesDeleteEndpoint() async throws {
        let apiService = RealtimeApiServiceStub(
            responses: [.success(Data("{}".utf8))]
        )
        let service = RealtimeSessionService(apiService: apiService)

        try await service.closeSession(sessionID: "session-4")

        XCTAssertEqual(
            apiService.requests,
            [
                RealtimeApiRequest(
                    method: .delete,
                    path: "/session/session-4",
                    body: nil
                )
            ]
        )
    }

    func testHeartbeatReportsInactiveSessionAndStopsCycle() async {
        let apiService = RealtimeApiServiceStub(
            responses: [
                .success(
                    Data(
                        #"""
                        {
                            "sessionUid": "session-5",
                            "status": "CLOSED",
                            "closeReason": "generation ended"
                        }
                        """#.utf8
                    )
                )
            ]
        )
        let manualSleeper = ManualRealtimeHeartbeatSleeper()
        let service = RealtimeSessionService(
            apiService: apiService,
            heartbeatSleeper: manualSleeper.sleeper
        )
        let failure = expectation(description: "heartbeat failure")

        service.startHeartbeat(sessionID: "session-5") { sessionID, error in
            XCTAssertEqual(sessionID, "session-5")
            XCTAssertEqual(
                error,
                XmaxError(
                    code: .sessionError,
                    message: "generation ended"
                )
            )
            failure.fulfill()
        }
        manualSleeper.resume()

        await fulfillment(of: [failure], timeout: 1)
        XCTAssertEqual(apiService.requests.count, 1)
        XCTAssertEqual(apiService.requests.first?.method, .put)
        XCTAssertEqual(
            apiService.requests.first?.path,
            "/session/session-5/heartbeat"
        )
    }

    func testStoppedHeartbeatIgnoresLateRequestFailure() async {
        let pendingResponse = PendingRealtimeApiResponse()
        let apiService = RealtimeApiServiceStub(
            responses: [.pending(pendingResponse)]
        )
        let manualSleeper = ManualRealtimeHeartbeatSleeper()
        let service = RealtimeSessionService(
            apiService: apiService,
            heartbeatSleeper: manualSleeper.sleeper
        )
        let failure = expectation(description: "stale failure ignored")
        failure.isInverted = true

        service.startHeartbeat(sessionID: "session-6") { _, _ in
            failure.fulfill()
        }
        manualSleeper.resume()
        await waitForRequest(apiService)

        service.stopHeartbeat()
        pendingResponse.resolve(
            .failure(
                XmaxError(code: .networkError, message: "late failure")
            )
        )

        await fulfillment(of: [failure], timeout: 0.05)
        XCTAssertEqual(apiService.requests.count, 1)
    }
}

private extension RealtimeSessionServiceTests {
    func waitForRequest(_ apiService: RealtimeApiServiceStub) async {
        for _ in 0..<1_000 where apiService.requests.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(apiService.requests.isEmpty)
    }
}

private struct RealtimeApiRequest: Equatable, Sendable {
    let method: ApiMethod
    let path: String
    let body: Data?
}

private final class RealtimeApiServiceStub: ApiServicing, @unchecked Sendable {

    // 并发状态
    private let lock = NSLock()
    private var storedResponses: [RealtimeApiResponse]
    private var storedRequests: [RealtimeApiRequest] = []

    init(responses: [RealtimeApiResponse]) {
        storedResponses = responses
    }

    var requests: [RealtimeApiRequest] {
        lock.withLock { storedRequests }
    }

    func request<Response: Decodable & Sendable>(
        _ method: ApiMethod,
        path: String,
        body: Data?,
        as responseType: Response.Type
    ) async throws -> Response {
        let behavior: RealtimeApiResponse = try lock.withLock {
            storedRequests.append(
                RealtimeApiRequest(method: method, path: path, body: body)
            )
            guard !storedResponses.isEmpty else {
                throw XmaxError(
                    code: .internalError,
                    message: "Missing test API response"
                )
            }
            return storedResponses.removeFirst()
        }

        let data: Data
        switch behavior {
        case .success(let value):
            data = value
        case .failure(let error):
            throw error
        case .pending(let response):
            data = try await response.value()
        }
        return try JSONDecoder().decode(responseType, from: data)
    }
}

private enum RealtimeApiResponse: Sendable {
    case success(Data)
    case failure(XmaxError)
    case pending(PendingRealtimeApiResponse)
}

private final class PendingRealtimeApiResponse: @unchecked Sendable {

    // 并发状态
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        Result<Data, XmaxError>,
        Never
    >?
    private var resolvedValue: Result<Data, XmaxError>?

    func value() async throws -> Data {
        let result = await withCheckedContinuation { continuation in
            let immediateValue: Result<Data, XmaxError>? = lock.withLock {
                if let resolvedValue {
                    return resolvedValue
                }
                self.continuation = continuation
                return nil
            }
            if let immediateValue {
                continuation.resume(returning: immediateValue)
            }
        }
        return try result.get()
    }

    func resolve(_ result: Result<Data, XmaxError>) {
        let continuation: CheckedContinuation<
            Result<Data, XmaxError>,
            Never
        >? = lock.withLock {
            guard resolvedValue == nil else {
                return nil
            }
            resolvedValue = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

private final class ManualRealtimeHeartbeatSleeper: @unchecked Sendable {

    // 异步事件流
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation!
    }

    var sleeper: RealtimeHeartbeatSleeper {
        RealtimeHeartbeatSleeper { [stream] in
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() != nil else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        }
    }

    func resume() {
        continuation.yield()
    }
}
