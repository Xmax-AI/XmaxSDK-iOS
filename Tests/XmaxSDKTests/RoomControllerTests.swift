//
//  RoomControllerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import XCTest
@testable import XmaxSDK

final class RoomControllerTests: XCTestCase {
    func testCancelledTargetSizeChangeDoesNotSendSignal() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RoomController(rtcManager: rtcManager)
        try await controller.join(connection: connection, ensureActive: {})
        do {
            try await controller.changeTargetSize(
                taskID: "task-id",
                targetSize: CGSize(width: 702, height: 1242),
                ensureActive: { throw XmaxError(code: .cancelled, message: "cancelled") }
            )
            XCTFail("Expected cancelled size change")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertTrue(rtcManager.controllerMessages.isEmpty)
        await controller.leave()
    }

    func testJoinForwardsConnectionAndLeaveReleasesRoom() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RoomController(rtcManager: rtcManager)

        try await controller.join(
            connection: connection,
            ensureActive: {}
        )
        await controller.leave()
        await controller.leave()

        XCTAssertEqual(
            rtcManager.calls,
            [
                .joinRoom(
                    RoomJoinConfiguration(
                        roomID: "room-id",
                        userID: "user-id",
                        token: "room-token"
                    )
                ),
                .leaveRoom
            ]
        )
    }

    func testJoinRejectsAnotherRoomUntilLeave() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RoomController(rtcManager: rtcManager)
        try await controller.join(
            connection: connection,
            ensureActive: {}
        )

        do {
            try await controller.join(
                connection: connection,
                ensureActive: {}
            )
            XCTFail("Expected duplicate room join to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Leave the current RTC room before " +
                        "joining another one"
                )
            )
        }

        await controller.leave()
    }

    func testJoinFailureRollsBackRoomResources() async {
        let expectedError = XmaxError(
            code: .rtcError,
            message: "join failed"
        )
        let rtcManager = RtcManagingStub(joinRoomError: expectedError)
        let controller = RoomController(rtcManager: rtcManager)

        do {
            try await controller.join(
                connection: connection,
                ensureActive: {}
            )
            XCTFail("Expected room join to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }

        XCTAssertEqual(
            rtcManager.calls,
            [
                .joinRoom(
                    RoomJoinConfiguration(
                        roomID: "room-id",
                        userID: "user-id",
                        token: "room-token"
                    )
                ),
                .leaveRoom
            ]
        )
    }

    func testInactiveJoinAfterAsyncBoundaryLeavesRoom() async {
        let expectedError = XmaxError(
            code: .cancelled,
            message: "connection replaced"
        )
        let counter = LockedInvocationCounter()
        let rtcManager = RtcManagingStub()
        let controller = RoomController(rtcManager: rtcManager)

        do {
            try await controller.join(
                connection: connection,
                ensureActive: {
                    if counter.increment() == 2 {
                        throw expectedError
                    }
                }
            )
            XCTFail("Expected inactive join to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }

        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(rtcManager.calls.last, .leaveRoom)
    }

    func testGenerationSignalsUseJoinedUserAndRoomProtocol() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RoomController(rtcManager: rtcManager)
        try await controller.join(
            connection: connection,
            ensureActive: {}
        )
        let format = RealtimeVideoFormat(
            width: 720,
            height: 1280,
            fps: 24
        )

        try await controller.startGeneration(
            taskID: "task-id",
            videoFormat: format,
            context: RealtimeContext(prompt: "first")
        )
        try await controller.changeGenerationCondition(
            taskID: "task-id",
            videoFormat: format,
            context: RealtimeContext(prompt: "second")
        )
        try await controller.sendTracks(
            taskID: "task-id",
            points: [RealtimePoint(x: 0.431231, y: 0.56931)]
        )
        try await controller.stopGeneration(taskID: "task-id")

        let events = try rtcManager.controllerMessages.map(decode)
        XCTAssertEqual(
            events.compactMap { $0["event"] as? String },
            ["start", "change_condition", "tracks", "stop"]
        )
        XCTAssertTrue(
            events.allSatisfy { $0["user_id"] as? String == "user-id" }
        )
        XCTAssertEqual(events[2]["tracks"] as? [[Double]], [[0.431231, 0.56931]])
        XCTAssertEqual(rtcManager.replacementKeys, [nil, nil, "tracks:task-id", nil])
        XCTAssertEqual(rtcManager.discardedKeys, [nil, nil, nil])
        await controller.leave()
    }

    func testGenerationSignalFailuresPreserveErrorDetails() async throws {
        let expectedError = XmaxError(
            code: .rtcError,
            message: "send failed"
        )
        let rtcManager = RtcManagingStub(sendRoomMessageError: expectedError)
        let controller = RoomController(rtcManager: rtcManager)
        try await controller.join(
            connection: connection,
            ensureActive: {}
        )
        let format = RealtimeVideoFormat(
            width: 720,
            height: 1280,
            fps: 24
        )

        do {
            try await controller.startGeneration(
                taskID: "task-id",
                videoFormat: format,
                context: RealtimeContext(prompt: "prompt")
            )
            XCTFail("Expected start signal to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }

        do {
            try await controller.stopGeneration(taskID: "task-id")
            XCTFail("Expected stop signal to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        await controller.leave()
    }

    func testGenerationSignalRequiresJoinedRoom() async {
        let rtcManager = RtcManagingStub()
        let controller = RoomController(rtcManager: rtcManager)

        do {
            try await controller.startGeneration(
                taskID: "task-id",
                videoFormat: RealtimeVideoFormat(
                    width: 720,
                    height: 1280,
                    fps: 24
                ),
                context: RealtimeContext(prompt: "prompt")
            )
            XCTFail("Expected generation signal to require a room")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .rtcError,
                    message: "RTC room is not joined"
                )
            )
        }
        XCTAssertTrue(rtcManager.controllerMessages.isEmpty)
    }

    func testEmptyOptionalSignalsAreIgnored() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RoomController(rtcManager: rtcManager)
        try await controller.join(
            connection: connection,
            ensureActive: {}
        )

        try await controller.stopGeneration(taskID: "")
        try await controller.sendTracks(taskID: "task-id", points: [])

        XCTAssertTrue(rtcManager.controllerMessages.isEmpty)
        await controller.leave()
    }

    func testPreviouslyReceivedStopConfirmationAllowsRestart() async throws {
        let rtc = RtcManagingStub()
        let controller = RoomController(rtcManager: rtc, redundantSignalingEnabled: false)
        let format = RealtimeVideoFormat(width: 720, height: 1280, fps: 30)
        let context = RealtimeContext(prompt: "test")
        let received = expectation(description: "Service already reported the previous task stopped")
        try await controller.join(connection: connection, ensureActive: {})
        try await controller.startGeneration(taskID: "previous?os=ios", videoFormat: format, context: context)
        await controller.setRoomMessageListener { message in
            if message.event == "video_stopped" { received.fulfill() }
        }
        rtc.emitRoomMessage(sender: "bot-user", message: #"{"event":"video_stopped","uid":"previous"}"#)
        await fulfillment(of: [received], timeout: 1)
        try await controller.stopGeneration(taskID: "previous?os=ios", confirmationSender: "bot-user")

        let sent = expectation(description: "Restart does not need a second stop notification")
        let restart = Task {
            try await controller.startGeneration(taskID: "next?os=ios", videoFormat: format, context: context)
            sent.fulfill()
        }
        await fulfillment(of: [sent], timeout: 1)
        restart.cancel()
        try await restart.value
        XCTAssertEqual(try rtc.controllerMessages.map { try decode($0)["event"] as? String }, ["start", "stop", "start"])
        await controller.leave()
    }
}

private extension RoomControllerTests {
    var connection: RealtimeSessionConnection {
        RealtimeSessionConnection(
            roomID: "room-id",
            userID: "user-id",
            token: "room-token",
            botName: "bot-user"
        )
    }

    func decode(_ message: String) throws -> [String: Any] {
        let data = try XCTUnwrap(message.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {

    // 并发状态
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            storedValue += 1
            return storedValue
        }
    }
}

private extension RtcManagingStub {
    var controllerMessages: [String] {
        calls.compactMap { call in
            guard case .sendRoomMessage(let message) = call else {
                return nil
            }
            return message
        }
    }
}

extension RoomControllerTests {
    func testAckFiltersSenderRecipientAndOldRoomBeforeStoppingRetries() async throws {
        let clock = CommandTestClock()
        let rtc = RtcManagingStub()
        let controller = RoomController(rtcManager: rtc, commandSleep: clock.sleep)
        try await controller.join(connection: connection, ensureActive: {})
        try await controller.startGeneration(
            taskID: "task", videoFormat: RealtimeVideoFormat(width: 720, height: 1280, fps: 24),
            context: RealtimeContext(prompt: "test")
        )
        for _ in 0..<1000 where clock.waiterCount != 6 { await Task.yield() }
        let event = try decode(XCTUnwrap(rtc.controllerMessages.first))
        let xid = try XCTUnwrap(event["xid"] as? String)
        for (sender, recipient, count) in [("intruder", "user-id", "1"), ("user-id", "user-id", "1"), ("bot-user", "other-user", "1"), ("bot-user", "user-id", "0")] {
            rtc.emitRoomMessage(sender: sender, message: "{\"event\":\"xid_ack\",\"xid\":\"\(xid)\",\"user_id\":\"\(recipient)\",\"count\":\(count)}")
        }
        // An actor barrier makes every preceding callback observable before checking the clock.
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(clock.waiterCount, 6)
        rtc.emitRoomMessage(sender: "bot-user", message: "{\"event\":\"xid_ack\",\"xid\":\"\(xid)\",\"count\":1}")
        for _ in 0..<1000 where clock.waiterCount != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(clock.waiterCount, 0)
        await controller.leave()
        try await controller.join(connection: connection, ensureActive: {})
        try await controller.startGeneration(
            taskID: "task2", videoFormat: RealtimeVideoFormat(width: 720, height: 1280, fps: 24),
            context: RealtimeContext(prompt: "test")
        )
        for _ in 0..<1000 where clock.waiterCount != 6 { await Task.yield() }
        rtc.emitRoomMessage(sender: "bot-user", message: "{\"event\":\"xid_ack\",\"xid\":\"\(xid)\",\"count\":1}")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(clock.waiterCount, 6)
        await controller.leave()
        for _ in 0..<1000 where clock.waiterCount != 0 { await Task.yield() }
        XCTAssertEqual(clock.waiterCount, 0)
    }
}
