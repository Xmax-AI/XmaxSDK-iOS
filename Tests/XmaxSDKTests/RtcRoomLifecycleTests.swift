//
//  RtcRoomLifecycleTests.swift
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

final class RtcRoomLifecycleTests: XCTestCase {
    func testJoinCancellationDestroysPendingRoomAndAllowsNextJoin() async throws {
        let started = expectation(description: "First join started")
        let first = RtcRoomStub(onJoin: { started.fulfill() })
        let nextStarted = expectation(description: "Next join started")
        let second = RtcRoomStub(onJoin: { nextStarted.fulfill() })
        let manager = makeManager { $0 == "first" ? first : second }
        try await manager.initialize()

        let joining = Task { try await manager.joinRoom(configuration: config("first")) }
        await fulfillment(of: [started], timeout: 2)
        joining.cancel()
        await expectFailure(joining, code: .cancelled)
        XCTAssertEqual(first.destroyCount, 1)

        let next = Task { try await manager.joinRoom(configuration: config("second")) }
        await fulfillment(of: [nextStarted], timeout: 2)
        first.emit(.joined, late: true)
        first.emit(.failure(XmaxError(code: .rtcError, message: "late")), late: true)
        second.emit(.joined)
        try await next.value
        try manager.publishLocalVideo()
        XCTAssertEqual(second.publishedVideo, [true])
        XCTAssertTrue(first.publishedVideo.isEmpty)
        await manager.destroy()
    }

    func testLeaveDuringJoinCancelsWaiterAndIgnoresLateSuccess() async throws {
        let started = expectation(description: "Join started")
        let room = RtcRoomStub(onJoin: { started.fulfill() })
        let manager = makeManager { _ in room }
        try await manager.initialize()

        let joining = Task { try await manager.joinRoom(configuration: config("room")) }
        await fulfillment(of: [started], timeout: 2)
        await manager.leaveRoom()
        await expectFailure(joining, code: .cancelled)
        room.emit(.joined, late: true)
        XCTAssertThrowsError(try manager.publishLocalVideo())
        await manager.leaveRoom()
        XCTAssertEqual(room.destroyCount, 1)
        await manager.destroy()
    }

    func testJoinTimeoutDestroysOnlyPendingRoom() async throws {
        let room = RtcRoomStub()
        let manager = makeManager(timeout: 10000000) { _ in room }
        try await manager.initialize()

        let joining = Task { try await manager.joinRoom(configuration: config("room")) }
        await expectFailure(joining, code: .timeout)
        XCTAssertEqual(room.destroyCount, 1)
        room.emit(.joined, late: true)
        XCTAssertThrowsError(try manager.sendRoomMessage("{}"))
        await manager.destroy()
    }

    func testImmediateJoinFailureCleansRoomAndReturnsOriginalError() async throws {
        let expected = XmaxError(code: .rtcError, message: "join rejected")
        let room = RtcRoomStub(onJoin: { throw expected })
        let manager = makeManager { _ in room }
        try await manager.initialize()

        do {
            try await manager.joinRoom(configuration: config("room"))
            XCTFail("Expected join failure")
        } catch {
            XCTAssertEqual(error as? XmaxError, expected)
        }
        XCTAssertEqual(room.destroyCount, 1)
        await manager.destroy()
    }

    func testAsynchronousJoinFailureCleansPendingRoom() async throws {
        let started = expectation(description: "Join started")
        let room = RtcRoomStub(onJoin: { started.fulfill() })
        let manager = makeManager { _ in room }
        try await manager.initialize()
        let joining = Task { try await manager.joinRoom(configuration: config("room")) }
        await fulfillment(of: [started], timeout: 2)

        room.emit(.failure(XmaxError(code: .rtcError, message: "token rejected")))
        await expectFailure(joining, code: .rtcError)
        XCTAssertEqual(room.destroyCount, 1)
        await manager.destroy()
    }

    func testDestroyDuringJoinReleasesRoomAndEngineOnce() async throws {
        let started = expectation(description: "Join started")
        let destroyed = expectation(description: "Engine destroyed")
        let room = RtcRoomStub(onJoin: { started.fulfill() })
        let platform = RtcPlatformStub(makeRoom: { _ in room })
        let manager = RtcManager(
            engineManager: RtcEngineManager(
                makeEngine: { _ in platform },
                destroyEngine: { destroyed.fulfill() }
            ))
        try await manager.initialize()
        let joining = Task { try await manager.joinRoom(configuration: config("room")) }
        await fulfillment(of: [started], timeout: 2)

        await manager.destroy()
        await expectFailure(joining, code: .cancelled)
        await fulfillment(of: [destroyed], timeout: 2)
        await manager.destroy()
        XCTAssertEqual(room.destroyCount, 1)
        XCTAssertThrowsError(try manager.useExternalVideoSource())
    }

    func testRoomReceivesAccountAndMessagesWithoutVendorConversion() async throws {
        let started = expectation(description: "Join started")
        let flushed = expectation(description: "Messages flushed")
        let room = RtcRoomStub(onJoin: { started.fulfill() }, onFlush: { flushed.fulfill() })
        let manager = makeManager { _ in room }
        try await manager.initialize()
        let configuration = config("room")
        let joining = Task { try await manager.joinRoom(configuration: configuration) }
        await fulfillment(of: [started], timeout: 2)
        room.emit(.joined)
        try await joining.value

        try manager.sendRoomMessage("{\"event\":\"start\"}")
        try await manager.awaitPendingMessages()
        await fulfillment(of: [flushed], timeout: 2)
        XCTAssertEqual(room.configurations, [configuration])
        XCTAssertEqual(room.messages, ["{\"event\":\"start\"}"])
        await manager.destroy()
    }

    func testOldRoomEventsCannotReachListenerAfterRejoin() async throws {
        let firstStarted = expectation(description: "First join")
        let secondStarted = expectation(description: "Second join")
        let first = RtcRoomStub(onJoin: { firstStarted.fulfill() })
        let second = RtcRoomStub(onJoin: { secondStarted.fulfill() })
        let manager = makeManager { $0 == "first" ? first : second }
        let listener = await MainActor.run { RoomEventRecorder() }
        manager.setEventListener(listener)
        try await manager.initialize()

        let firstJoin = Task { try await manager.joinRoom(configuration: config("first")) }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.emit(.joined)
        try await firstJoin.value
        await manager.leaveRoom()

        let secondJoin = Task { try await manager.joinRoom(configuration: config("second")) }
        await fulfillment(of: [secondStarted], timeout: 2)
        second.emit(.joined)
        try await secondJoin.value
        first.emit(.publication(userID: "old", published: true), late: true)
        first.emit(.failure(XmaxError(code: .rtcError, message: "old failure")), late: true)
        let delivered = expectation(description: "Current event delivered")
        await MainActor.run { listener.onPublication = { delivered.fulfill() } }
        second.emit(.publication(userID: "current", published: true))
        await fulfillment(of: [delivered], timeout: 2)

        await MainActor.run {
            XCTAssertEqual(listener.users, ["current"])
            XCTAssertTrue(listener.failures.isEmpty)
        }
        await manager.destroy()
    }

    @MainActor
    func testStatisticsForwardOnlyCurrentRoomAfterRejoin() async throws {
        let firstStarted = expectation(description: "First room")
        let secondStarted = expectation(description: "Second room")
        let first = RtcRoomStub(onJoin: { firstStarted.fulfill() })
        let second = RtcRoomStub(onJoin: { secondStarted.fulfill() })
        let manager = makeManager { $0 == "first" ? first : second }
        let quality = QualityController(rtcManager: manager)
        quality.setUplinkVideoStatisticsEnabled(true)
        quality.setDownlinkVideoStatisticsUser("bot")
        var uplinkRates: [Int] = []
        var downlinkRates: [Int] = []
        let delivered = expectation(description: "Current statistics")
        delivered.expectedFulfillmentCount = 2
        quality.setUplinkVideoStatisticsListener {
            guard let rate = $0?.sendFrameRate else { return }
            uplinkRates.append(rate)
            delivered.fulfill()
        }
        quality.setDownlinkVideoStatisticsListener {
            guard let rate = $0?.decodeFrameRate else { return }
            downlinkRates.append(rate)
            delivered.fulfill()
        }
        try await manager.initialize()
        let firstJoin = Task { try await manager.joinRoom(configuration: config("first")) }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.emit(.joined)
        try await firstJoin.value
        await manager.leaveRoom()

        let secondJoin = Task { try await manager.joinRoom(configuration: config("second")) }
        await fulfillment(of: [secondStarted], timeout: 2)
        second.emit(.joined)
        try await secondJoin.value
        first.emit(.uplinkVideoStatistics(UplinkVideoStatistics(sendFrameRate: 60)), late: true)
        first.emit(.downlinkVideoStatistics(DownlinkVideoStatistics(userID: "bot", decodeFrameRate: 60)), late: true)
        second.emit(.uplinkVideoStatistics(UplinkVideoStatistics(sendFrameRate: 30)))
        second.emit(.downlinkVideoStatistics(DownlinkVideoStatistics(userID: "bot", decodeFrameRate: 24)))
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertEqual(uplinkRates, [30])
        XCTAssertEqual(downlinkRates, [24])
        await manager.destroy()
    }

    func testOldRoomAudioCannotReachListenerAfterRejoiningSameRoomName() async throws {
        let firstStarted = expectation(description: "First room")
        let secondStarted = expectation(description: "Second room")
        let first = RtcRoomStub(onJoin: { firstStarted.fulfill() })
        let second = RtcRoomStub(onJoin: { secondStarted.fulfill() })
        let rooms = AudioRoomSequence(first: first, second: second)
        let manager = makeManager { _ in rooms.next() }
        try await manager.initialize()
        let firstJoin = Task { try await manager.joinRoom(configuration: config("same-room")) }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.emit(.joined)
        try await firstJoin.value
        let stream = RemoteStream(roomID: "same-room", userID: "bot")
        let old = expectation(description: "Old listener rejected")
        old.isInverted = true
        try manager.setRemoteAudioFrameListener({ _ in old.fulfill() }, for: stream)
        await manager.leaveRoom()

        let secondJoin = Task { try await manager.joinRoom(configuration: config("same-room")) }
        await fulfillment(of: [secondStarted], timeout: 2)
        second.emit(.joined)
        try await secondJoin.value
        let current = expectation(description: "Current room audio")
        try manager.setRemoteAudioFrameListener({ _ in current.fulfill() }, for: stream)
        first.emitAudioFrame(audioPacket(1_000), late: true)
        second.emitAudioFrame(audioPacket(2_000))
        await fulfillment(of: [current, old], timeout: 0.2)
        await manager.destroy()
        XCTAssertNoThrow(try manager.setRemoteAudioFrameListener(nil, for: stream))
        XCTAssertThrowsError(try manager.setRemoteAudioFrameListener({ _ in }, for: stream))
    }

    private func makeManager(
        timeout: UInt64 = RtcManager.joinTimeoutNanoseconds,
        makeRoom: @escaping @Sendable (String) throws -> any RtcRoom
    ) -> RtcManager {
        let platform = RtcPlatformStub(makeRoom: makeRoom)
        return RtcManager(
            engineManager: RtcEngineManager(makeEngine: { _ in platform }, destroyEngine: {}),
            joinTimeoutNanoseconds: timeout
        )
    }

    private func expectFailure(_ task: Task<Void, any Error>, code: XmaxErrorCode) async {
        do {
            try await task.value
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, code)
        }
    }
}

private func config(_ roomID: String) -> RoomJoinConfiguration {
    RoomJoinConfiguration(roomID: roomID, userID: "string-account", token: "token")
}

private final class AudioRoomSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let first: RtcRoomStub
    private let second: RtcRoomStub
    private var usedFirst = false

    init(first: RtcRoomStub, second: RtcRoomStub) {
        self.first = first
        self.second = second
    }

    func next() -> RtcRoomStub {
        lock.withLock {
            defer { usedFirst = true }
            return usedFirst ? second : first
        }
    }
}

@MainActor
private final class RoomEventRecorder: RtcEventListener {
    var users: [String] = []
    var failures: [XmaxError] = []
    var onPublication: (() -> Void)?

    func onRemoteVideoPublished(userID: String, published: Bool) {
        users.append(userID)
        onPublication?()
    }

    func onRtcFailure(_ error: XmaxError) {
        failures.append(error)
    }
}

extension RtcRoomLifecycleTests {
    func testIncomingMessagesAreDeliveredOnlyForCurrentJoinedRoom() async throws {
        let firstStarted = expectation(description: "first room entering")
        let secondStarted = expectation(description: "second room entering")
        let first = RtcRoomStub(onJoin: { firstStarted.fulfill() })
        let second = RtcRoomStub(onJoin: { secondStarted.fulfill() })
        let rooms = AudioRoomSequence(first: first, second: second)
        let manager = makeManager { _ in rooms.next() }
        try await manager.initialize()
        let received = expectation(description: "current room message")
        manager.setRoomMessageListener { sender, data in
            XCTAssertEqual(sender, "bot")
            XCTAssertEqual(data, Data("current".utf8))
            received.fulfill()
        }
        let joining = Task { try await manager.joinRoom(configuration: config("first")) }
        await fulfillment(of: [firstStarted], timeout: 1)
        first.emit(.message(userID: "bot", data: Data("before-join".utf8)))
        first.emit(.joined)
        try await joining.value
        await manager.leaveRoom()
        let rejoining = Task { try await manager.joinRoom(configuration: config("second")) }
        await fulfillment(of: [secondStarted], timeout: 1)
        second.emit(.joined)
        try await rejoining.value
        first.emit(.message(userID: "bot", data: Data("old-room".utf8)), late: true)
        second.emit(.message(userID: "bot", data: Data("current".utf8)))
        await fulfillment(of: [received], timeout: 1)
        await manager.destroy()
    }
}
