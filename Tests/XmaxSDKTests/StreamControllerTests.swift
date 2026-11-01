//
//  StreamControllerTests.swift
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

final class StreamControllerTests: XCTestCase {
    @MainActor
    func testStatisticsFollowPublicationResultStreamAndDisconnect() async throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)
        var uplink: UplinkVideoStatistics?
        var downlink: DownlinkVideoStatistics?
        var uplinkSamples = 0
        var downlinkSamples = 0
        let uplinkCleared = expectation(description: "Uplink cleared")
        let downlinkCleared = expectation(description: "Downlink cleared")
        controller.setUplinkVideoStatisticsListener {
            uplink = $0
            if $0 != nil { uplinkSamples += 1 }
            if uplinkSamples > 0 && $0 == nil { uplinkCleared.fulfill() }
        }
        controller.setDownlinkVideoStatisticsListener {
            downlink = $0
            if $0 != nil { downlinkSamples += 1 }
            if downlinkSamples > 0 && $0 == nil { downlinkCleared.fulfill() }
        }

        let local = UplinkVideoStatistics(captureFrameRate: 30)
        let remote = DownlinkVideoStatistics(userID: "bot-user", decodeFrameRate: 24)
        rtcManager.emitUplinkVideoStatistics(local)
        rtcManager.emitDownlinkVideoStatistics(remote)
        XCTAssertEqual(uplinkSamples, 0)
        XCTAssertEqual(downlinkSamples, 0)

        let confirmation = try await startGeneration(controller, taskID: "task")
        rtcManager.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
        try await confirmation.value
        rtcManager.emitUplinkVideoStatistics(local)
        rtcManager.emitDownlinkVideoStatistics(remote)
        XCTAssertEqual(uplink, local)
        XCTAssertEqual(downlink, remote)

        await controller.disconnect()
        await fulfillment(of: [uplinkCleared, downlinkCleared], timeout: 1)
        rtcManager.emitUplinkVideoStatistics(local)
        rtcManager.emitDownlinkVideoStatistics(remote)
        XCTAssertNil(uplink)
        XCTAssertNil(downlink)
        XCTAssertEqual(uplinkSamples, 1)
        XCTAssertEqual(downlinkSamples, 1)
    }

    func testPublishLocalCameraStreamRequiresConfiguredRoom() {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)

        XCTAssertThrowsError(
            try controller.publishLocalStream(includeAudio: false)
        ) { error in
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Configure an RTC room before publishing " +
                        "the local stream"
                )
            )
        }
        XCTAssertTrue(rtcManager.calls.isEmpty)
    }

    func testPublishLocalCameraStreamPublishesVideoOnlyOnce() throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)
        try controller.configureRoom(
            roomID: " room-id ",
            botName: nil
        )

        try controller.publishLocalStream(includeAudio: false)
        try controller.publishLocalStream(includeAudio: false)

        XCTAssertEqual(rtcManager.calls, [.publishLocalVideo])
    }

    func testPublishLocalStreamPublishesAudioAndVideoOnlyOnce() throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)
        try controller.configureRoom(roomID: "room-id", botName: nil)

        try controller.publishLocalStream(includeAudio: true)
        try controller.publishLocalStream(includeAudio: true)

        XCTAssertEqual(
            rtcManager.calls,
            [.publishLocalVideo, .publishLocalAudio]
        )
    }

    func testAudioPublicationFailureRollsBackNewVideoPublication() throws {
        let expectedError = XmaxError(
            code: .rtcError,
            message: "Failed to publish local audio"
        )
        let rtcManager = RtcManagingStub(
            publishLocalAudioError: expectedError
        )
        let controller = StreamController(rtcManager: rtcManager)
        try controller.configureRoom(roomID: "room-id", botName: nil)

        XCTAssertThrowsError(
            try controller.publishLocalStream(includeAudio: true)
        ) { error in
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        XCTAssertEqual(
            rtcManager.calls,
            [
                .publishLocalVideo,
                .publishLocalAudio,
                .unpublishLocalVideo
            ]
        )
    }

    @MainActor
    func testRemoteVideoEventsSubscribeOnlyConfiguredBot() throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)
        try controller.configureRoom(
            roomID: "room-id",
            botName: " bot-user "
        )

        rtcManager.emitRemoteVideoPublished(
            userID: "another-user",
            published: true
        )
        rtcManager.emitRemoteVideoPublished(
            userID: "bot-user",
            published: true
        )
        rtcManager.emitRemoteVideoPublished(
            userID: "bot-user",
            published: true
        )
        rtcManager.emitRemoteVideoPublished(
            userID: "bot-user",
            published: false
        )
        rtcManager.emitRemoteVideoPublished(
            userID: "bot-user",
            published: true
        )

        XCTAssertEqual(
            rtcManager.calls,
            [
                .subscribeRemoteVideo(
                    userID: "bot-user",
                    subscribe: true
                ),
                .subscribeRemoteVideo(
                    userID: "bot-user",
                    subscribe: true
                )
            ]
        )
    }

    @MainActor
    func testRemoteVideoSubscriptionFailureReportsError() throws {
        let subscriptionError = XmaxError(
            code: .rtcError,
            message: "subscribe failed"
        )
        let rtcManager = RtcManagingStub(
            subscribeRemoteVideoError: subscriptionError
        )
        let receivedErrors = StreamErrorRecorder()
        let controller = StreamController(
            rtcManager: rtcManager,
            errorListener: { receivedErrors.append($0) }
        )
        try controller.configureRoom(
            roomID: "room-id",
            botName: "bot-user"
        )

        rtcManager.emitRemoteVideoPublished(
            userID: "bot-user",
            published: true
        )

        XCTAssertEqual(
            receivedErrors.values,
            [subscriptionError]
        )
    }

    @MainActor
    func testResetRoomClearsSubscriptionsAndLocalPublications() async throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)
        try controller.configureRoom(
            roomID: "room-id",
            botName: "bot-user"
        )
        try controller.publishLocalStream(includeAudio: true)
        rtcManager.emitRemoteVideoPublished(
            userID: "bot-user",
            published: true
        )

        await controller.resetStream()
        await controller.resetStream()

        XCTAssertEqual(
            rtcManager.calls,
            [
                .publishLocalVideo,
                .publishLocalAudio,
                .subscribeRemoteVideo(
                    userID: "bot-user",
                    subscribe: true
                ),
                .subscribeRemoteVideo(
                    userID: "bot-user",
                    subscribe: false
                ),
                .unpublishLocalAudio,
                .unpublishLocalVideo
            ]
        )
        XCTAssertThrowsError(
            try controller.publishLocalStream(includeAudio: false)
        ) { error in
            XCTAssertEqual(
                (error as? XmaxError)?.code,
                .invalidConfiguration
            )
        }
    }

    func testConfigureRoomRejectsReplacementWhilePublishing() throws {
        let controller = StreamController(rtcManager: RtcManagingStub())
        try controller.configureRoom(roomID: "first-room", botName: nil)
        try controller.publishLocalStream(includeAudio: false)

        XCTAssertThrowsError(
            try controller.configureRoom(
                roomID: "second-room",
                botName: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Reset the current RTC room before " +
                        "configuring another one"
                )
            )
        }
    }

    @MainActor
    func testGenerationConfirmationMatchesTaskRoomAndBot() async throws {
        let rtcManager = RtcManagingStub()
        var receivedStreams: [RemoteStream?] = []
        let controller = StreamController(
            rtcManager: rtcManager,
            remoteStreamListener: { stream in
                receivedStreams.append(stream)
            },
            generationTiming: StreamGenerationTiming(
                timeoutNanoseconds: 1_000_000_000
            )
        )
        try controller.configureRoom(
            roomID: "room-id",
            botName: "bot-user"
        )
        let confirmation = try await startGeneration(controller,
            taskID: "task-id"
        )
        let matchingStream = RemoteStream(
            roomID: "room-id",
            userID: "bot-user"
        )

        rtcManager.emitRemoteVideoPublished(userID: "other-user", published: true)
        rtcManager.emitRemoteVideoAvailable(stream: matchingStream)
        rtcManager.emitRemoteVideoAvailable(stream: matchingStream)
        try await confirmation.value

        XCTAssertEqual(receivedStreams.count, 1)
        XCTAssertEqual(receivedStreams[0], matchingStream)
        XCTAssertFalse(rtcManager.calls.contains(
            .subscribeRemoteAudio(
                userID: "bot-user",
                subscribe: true
            )
        ))
        try controller.activateRemoteAudio()
        XCTAssertTrue(rtcManager.calls.contains(
            .setRemoteAudioVolume(100, userID: "bot-user")
        ))
        XCTAssertTrue(rtcManager.calls.contains(
            .subscribeRemoteAudio(
                userID: "bot-user",
                subscribe: true
            )
        ))
        _ = await controller.stopStreamGeneration(taskID: "task-id")
        XCTAssertTrue(rtcManager.calls.contains(
            .subscribeRemoteAudio(
                userID: "bot-user",
                subscribe: false
            )
        ))
    }

    @MainActor
    func testRemoteAudioVolumeIsAppliedBeforeSubscription() async throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(
            rtcManager: rtcManager,
            generationTiming: StreamGenerationTiming(
                timeoutNanoseconds: 1_000_000_000
            )
        )
        try controller.setRemoteAudioVolume(0.35)
        try controller.configureRoom(
            roomID: "room-id",
            botName: "bot-user"
        )
        let confirmation = try await startGeneration(controller,
            taskID: "task-id"
        )

        rtcManager.emitRemoteVideoAvailable(stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try await confirmation.value
        try controller.activateRemoteAudio()

        let volumeIndex = try XCTUnwrap(rtcManager.calls.firstIndex(
            of: .setRemoteAudioVolume(35, userID: "bot-user")
        ))
        let subscriptionIndex = try XCTUnwrap(rtcManager.calls.firstIndex(
            of: .subscribeRemoteAudio(
                userID: "bot-user",
                subscribe: true
            )
        ))
        XCTAssertLessThan(volumeIndex, subscriptionIndex)
    }

    @MainActor
    func testGenerationConfirmationTimesOut() async throws {
        let controller = StreamController(
            rtcManager: RtcManagingStub(),
            generationTiming: StreamGenerationTiming(
                timeoutNanoseconds: 0
            )
        )
        try controller.configureRoom(roomID: "room-id", botName: nil)
        let confirmation = try controller.beginGenerationConfirmation(
            taskID: "task-id"
        )

        do {
            try await confirmation.value
            XCTFail("Expected generation confirmation to time out")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .timeout,
                    message: "Realtime generation start timed out"
                )
            )
        }
        _ = await controller.stopStreamGeneration(taskID: "task-id")
    }

    @MainActor
    func testStoppingGenerationCancelsWaitAndClearsRemoteStream() async throws {
        var receivedStreams: [RemoteStream?] = []
        let controller = StreamController(
            rtcManager: RtcManagingStub(),
            remoteStreamListener: { stream in
                receivedStreams.append(stream)
            }
        )
        try controller.configureRoom(roomID: "room-id", botName: nil)
        let confirmation = try controller.beginGenerationConfirmation(
            taskID: "task-id"
        )

        let stoppedTaskID = await controller.stopStreamGeneration(
            taskID: "task-id"
        )

        XCTAssertEqual(stoppedTaskID, "task-id")
        XCTAssertNil(receivedStreams.last ?? nil)
        do {
            try await confirmation.value
            XCTFail("Expected generation confirmation to be cancelled")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
    }

    @MainActor
    func testStoppingStaleGenerationDoesNotClearCurrentRemoteStream() async throws {
        var receivedStreams: [RemoteStream?] = []
        let rtcManager = RtcManagingStub()
        let controller = StreamController(
            rtcManager: rtcManager,
            remoteStreamListener: { stream in
                receivedStreams.append(stream)
            }
        )
        try controller.configureRoom(
            roomID: "room-id",
            botName: "bot-user"
        )
        let confirmation = try await startGeneration(controller,
            taskID: "current-task"
        )
        let currentStream = RemoteStream(
            roomID: "room-id",
            userID: "bot-user"
        )
        rtcManager.emitRemoteVideoAvailable(stream: currentStream)
        try await confirmation.value

        let stoppedTaskID = await controller.stopStreamGeneration(
            taskID: "stale-task"
        )

        XCTAssertTrue(stoppedTaskID.isEmpty)
        XCTAssertEqual(receivedStreams.count, 1)
        XCTAssertEqual(receivedStreams[0], currentStream)
    }

    @MainActor
    func testExternalVideoFrameWithoutGenerationIsIgnored() throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)
        let format = try VideoFormat(
            width: 2,
            height: 2,
            pixelFormat: .nv12
        )
        let frame = try VideoFrame(
            format: format,
            timestampUs: 0,
            planes: [
                try VideoFramePlane(
                    data: Data(repeating: 0, count: 4),
                    stride: 2
                ),
                try VideoFramePlane(
                    data: Data(repeating: 0, count: 2),
                    stride: 2
                )
            ]
        )

        try controller.pushLocalVideoFrame(frame)

        XCTAssertTrue(rtcManager.calls.isEmpty)
    }

    @MainActor
    func testPublishedBotBeforeStartIsConfirmedAfterSignalFlush() async throws {
        let rtc = RtcManagingStub()
        var streams: [RemoteStream?] = []
        let controller = StreamController(rtcManager: rtc, remoteStreamListener: { streams.append($0) })
        try await controller.connect(connection: RealtimeSessionConnection(
            roomID: "room-id", userID: "user-id", token: "token", botName: "bot-user"
        ), includeLocalAudio: false, ensureActive: {})
        rtc.emitRemoteVideoPublished(userID: "other-user", published: true)
        rtc.emitRemoteVideoPublished(userID: "bot-user", published: true)
        XCTAssertTrue(streams.isEmpty)

        let confirmation = try await controller.beginGeneration(
            taskID: "task", videoFormat: RealtimeVideoFormat(width: 1024, height: 1920, fps: 30),
            context: RealtimeContext(prompt: "test")
        )
        try await confirmation.value
        XCTAssertEqual(streams, [RemoteStream(roomID: "room-id", userID: "bot-user")])
        await controller.disconnect()
    }

    @MainActor
    func testPublicationWaitsForSignalFlushAndDisconnectCancelsConfirmation() async throws {
        let rtc = RtcManagingStub()
        let gate = AsyncStream<Void>.makeStream()
        rtc.commandSendHandler = {
            for await _ in gate.stream { break }
            try Task.checkCancellation()
        }
        var streams: [RemoteStream?] = []
        let controller = StreamController(rtcManager: rtc, remoteStreamListener: { streams.append($0) })
        try await controller.connect(connection: RealtimeSessionConnection(
            roomID: "room-id", userID: "user-id", token: "token", botName: "bot-user"
        ), includeLocalAudio: false, ensureActive: {})
        let start = Task {
            try await controller.beginGeneration(
                taskID: "task", videoFormat: RealtimeVideoFormat(width: 1024, height: 1920, fps: 30),
                context: RealtimeContext(prompt: "test")
            )
        }
        for _ in 0..<100 where !controller.hasGenerationTask { await Task.yield() }
        rtc.emitRemoteVideoPublished(userID: "bot-user", published: true)
        XCTAssertTrue(streams.isEmpty)
        await controller.disconnect()
        gate.continuation.yield()
        gate.continuation.finish()
        do {
            let confirmation = try await start.value
            try await confirmation.value
            XCTFail("Expected cancelled generation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertTrue(streams.allSatisfy { $0 == nil })
    }

    @MainActor
    func testExternalFramesDoNotCarryLegacySEI() async throws {
        let rtcManager = RtcManagingStub()
        let controller = StreamController(rtcManager: rtcManager)
        try await controller.connect(
            connection: RealtimeSessionConnection(
                roomID: "room-id", userID: "user-id", token: "token", botName: "bot-user"
            ),
            includeLocalAudio: false,
            ensureActive: {}
        )
        let format = try VideoFormat(
            width: 2,
            height: 2,
            pixelFormat: .nv12
        )
        let frame = try VideoFrame(
            format: format,
            timestampUs: 0,
            planes: [
                try VideoFramePlane(
                    data: Data(repeating: 0, count: 4),
                    stride: 2
                ),
                try VideoFramePlane(
                    data: Data(repeating: 0, count: 2),
                    stride: 2
                )
            ]
        )

        // 尚未生成时不推送视频帧。
        try controller.pushLocalVideoFrame(frame)
        let taskID = UUID().uuidString
        let videoFormat = RealtimeVideoFormat(width: 832, height: 1472, fps: 24)
        let confirmation = try await controller.beginGeneration(
            taskID: taskID, videoFormat: videoFormat, context: RealtimeContext(prompt: "first")
        )
        try controller.pushLocalVideoFrame(frame)
        try controller.pushLocalVideoFrame(frame)
        try await controller.updateGeneration(
            taskID: taskID, videoFormat: videoFormat, context: RealtimeContext(prompt: "second")
        )
        try controller.pushLocalVideoFrame(frame)
        try await controller.changeTargetSize(
            taskID: taskID, targetSize: CGSize(width: 702, height: 1242), ensureActive: {}
        )
        try controller.pushLocalVideoFrame(frame)
        try await controller.stopGeneration(taskID: taskID)
        do {
            try await confirmation.value
            XCTFail("Expected stopped confirmation to be cancelled")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }

        let messages = rtcManager.calls.compactMap { call -> String? in
            guard case .sendRoomMessage(let message) = call else { return nil }
            return message
        }
        XCTAssertEqual(messages.count, 4)
        for message in messages {
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
            XCTAssertEqual(event["uid"] as? String, taskID)
        }
        try controller.pushLocalVideoFrame(frame)
        let nextTaskID = UUID().uuidString
        let nextConfirmation = try controller.beginGenerationConfirmation(taskID: nextTaskID)
        try controller.pushLocalVideoFrame(frame)
        let frames = rtcManager.calls.filter { $0 == .pushExternalVideoFrame }
        XCTAssertEqual(frames.count, 5)
        _ = await controller.stopStreamGeneration(taskID: nextTaskID)
        do {
            try await nextConfirmation.value
            XCTFail("Expected stopped confirmation to be cancelled")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        await controller.disconnect()
    }
    @MainActor
    private func startGeneration(_ controller: StreamController, taskID: String) async throws -> Task<Void, any Error> {
        try await controller.connect(connection: RealtimeSessionConnection(
            roomID: "room-id", userID: "user-id", token: "token", botName: "bot-user"
        ), includeLocalAudio: false, ensureActive: {})
        return try await controller.beginGeneration(
            taskID: taskID, videoFormat: RealtimeVideoFormat(width: 1024, height: 1920, fps: 30),
            context: RealtimeContext(prompt: "test")
        )
    }
}

private final class StreamErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [XmaxError] = []

    var values: [XmaxError] {
        lock.withLock { errors }
    }

    func append(_ error: XmaxError) {
        lock.withLock {
            errors.append(error)
        }
    }
}
