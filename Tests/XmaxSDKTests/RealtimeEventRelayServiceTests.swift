import Foundation
import XCTest
@testable import XmaxSDK

@MainActor
final class RealtimeEventRelayServiceTests: XCTestCase {
    func testRelayPreservesCompleteCommandAndAcceptsNewAndDuplicateReceipts() async throws {
        let message =
            #"{"event":"start","xid":"command-1","uid":"task","params":{"prompt":"换装🙂","face_replace":true,"size":[1080,1920]}}"#
        for accepted in [true, false] {
            let response = try JSONSerialization.data(withJSONObject: [
                "xid": "command-1", "accepted": accepted,
            ])
            let api = RelayTestApiService { _ in response }
            let service = RealtimeEventRelayService(apiService: api)
            try await service.relay(sessionID: "session", modelID: "instance", message: message)
            XCTAssertEqual(api.requests.count, 1)
            let request = try XCTUnwrap(api.requests.first)
            XCTAssertEqual(request.method, .post)
            XCTAssertEqual(request.path, "/client-event/relay")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
            )
            XCTAssertEqual(body["sessionId"] as? String, "session")
            XCTAssertEqual(body["modelId"] as? String, "instance")
            let original =
                try JSONSerialization.jsonObject(with: Data(message.utf8)) as? NSDictionary
            XCTAssertEqual(body["data"] as? NSDictionary, original)
        }
    }

    func testInvalidReceiptsAreRejectedWithoutRetrying() async {
        for response in [
            #"{}"#,
            #"{"xid":"other","accepted":true}"#,
            #"{"xid":7,"accepted":true}"#,
            #"{"xid":"command-1"}"#,
            #"{"xid":"command-1","accepted":"false"}"#,
            #"{"xid":"command-1","accepted":1}"#,
            #"{"xid":"command-1","accepted":null}"#,
        ] {
            let api = RelayTestApiService { _ in Data(response.utf8) }
            do {
                try await RealtimeEventRelayService(apiService: api).relay(
                    sessionID: "session",
                    modelID: "instance",
                    message: command
                )
                XCTFail("Expected invalid receipt rejection")
            } catch {
                XCTAssertEqual(XmaxError.from(error).code, .apiError)
            }
            XCTAssertEqual(api.requests.count, 1)
        }
    }

    func testRelayPreservesAPIFailuresWithoutRetrying() async {
        for error in [
            XmaxError(code: .apiError, message: "Rejected", apiCode: 1003, httpStatus: 403),
            XmaxError(code: .networkError, message: "Offline"),
        ] {
            let api = RelayTestApiService { _ in throw error }
            do {
                try await RealtimeEventRelayService(apiService: api).relay(
                    sessionID: "session",
                    modelID: "instance",
                    message: command
                )
                XCTFail("Expected relay failure")
            } catch let received {
                XCTAssertEqual(received as? XmaxError, error)
            }
            XCTAssertEqual(api.requests.count, 1)
        }
    }

    func testCancellationReachesInFlightRequest() async throws {
        let entered = expectation(description: "HTTP request entered")
        let cancelled = expectation(description: "HTTP request cancelled")
        let api = RelayTestApiService { _ in
            entered.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return Data()
            } catch {
                if Task.isCancelled { cancelled.fulfill() }
                throw error
            }
        }
        let service = RealtimeEventRelayService(apiService: api)
        let message = command
        let task = Task {
            try await service.relay(sessionID: "session", modelID: "instance", message: message)
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual(XmaxError.from(error).code, .cancelled) }
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(api.requests.count, 1)
    }

    func testFactoryRelaysAllControlsAndSupportsSessionsWithoutModelInstance() async throws {
        for modelID in [nil, "instance"] as [String?] {
            var payload: [String: Any] = [
                "sessionUid": "session", "status": "ACTIVE",
                "modelExtra": [
                    "room_id": "room", "room_token": "token", "rtc_user_id": "user",
                    "rtc_bot_id": "bot", "rtc_app_id": RtcEngineManager.defaultAppID,
                ],
            ]
            payload["modelUid"] = modelID
            let session = try JSONSerialization.data(withJSONObject: payload)
            let api = RelayTestApiService { request in
                if request.path == "/session" { return session }
                if request.path == "/client-event/relay" {
                    let body =
                        try JSONSerialization.jsonObject(with: XCTUnwrap(request.body))
                        as! [String: Any]
                    let data = body["data"] as! [String: Any]
                    return try JSONSerialization.data(withJSONObject: [
                        "xid": data["xid"]!, "accepted": false,
                    ])
                }
                return Data(#"{"sessionUid":"session","status":"ACTIVE"}"#.utf8)
            }
            let rtc = RtcManagingStub()
            let options = RealtimeConfiguration(
                model: .x2_1,
                isFrameInterpolationEnabled: false,
                isAdaptiveQualityEnabled: false
            )
            let components = XmaxRealtimeFactory.make(
                options: options,
                apiService: api,
                rtcManager: rtc
            )
            let manager = XmaxRealtimeManager(options: options, components: components)
            let local = try await manager.createExternalVideoStream(
                source: RealtimeExternalVideoSourceStub()
            )
            let starting = Task {
                try await manager.startGeneration(
                    localStream: local,
                    context: RealtimeContext(prompt: "first")
                )
            }
            await eventually { self.messages(rtc).contains { $0.contains("\"start\"") } }
            rtc.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room", userID: "bot"))
            await eventually {
                rtc.calls.contains(
                    .setRemoteVideoFrameListener(
                        RemoteStream(roomID: "room", userID: "bot"),
                        enabled: true
                    )
                )
            }
            try rtc.emitRemoteVideoFrame()
            _ = try await starting.value
            try await manager.startGeneration(context: RealtimeContext(prompt: "second"))
            try await manager.setDownlinkQualityLevel(.l3)
            if modelID != nil {
                await eventually {
                    api.requests.filter { $0.path == "/client-event/relay" }.count == 3
                }
                let controls = try messages(rtc).compactMap { message -> [String: Any]? in
                    let object =
                        try JSONSerialization.jsonObject(with: Data(message.utf8)) as! [String: Any]
                    return ["start", "change_condition", "change_target_size"].contains(
                        object["event"] as? String ?? ""
                    ) ? object : nil
                }
                XCTAssertEqual(controls.count, 3)
                for request in api.requests where request.path == "/client-event/relay" {
                    let body =
                        try JSONSerialization.jsonObject(with: XCTUnwrap(request.body))
                        as! [String: Any]
                    XCTAssertEqual(body["sessionId"] as? String, "session")
                    XCTAssertEqual(body["modelId"] as? String, modelID)
                    let data = body["data"] as! NSDictionary
                    let original = controls.first { $0["xid"] as? String == data["xid"] as? String }
                    XCTAssertEqual(data, original as NSDictionary?)
                }
            }
            await manager.close()
            if modelID == nil {
                XCTAssertFalse(api.requests.contains { $0.path == "/client-event/relay" })
            }
        }
    }

    private var command: String { #"{"event":"start","xid":"command-1","uid":"task"}"# }

    private func messages(_ rtc: RtcManagingStub) -> [String] {
        rtc.calls.compactMap {
            if case .sendRoomMessage(let message) = $0 { return message }
            return nil
        }
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private struct RelayTestRequest: Sendable {
    let method: ApiMethod
    let path: String
    let body: Data?
}

private final class RelayTestApiService: ApiServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [RelayTestRequest] = []
    private let response: @Sendable (RelayTestRequest) async throws -> Data

    init(response: @escaping @Sendable (RelayTestRequest) async throws -> Data) {
        self.response = response
    }

    var requests: [RelayTestRequest] { lock.withLock { storedRequests } }

    func request<Response: Decodable & Sendable>(
        _ method: ApiMethod,
        path: String,
        body: Data?,
        as responseType: Response.Type
    ) async throws -> Response {
        let request = RelayTestRequest(method: method, path: path, body: body)
        lock.withLock { storedRequests.append(request) }
        return try JSONDecoder().decode(responseType, from: await response(request))
    }
}
