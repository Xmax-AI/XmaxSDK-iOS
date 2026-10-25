//
//  RenderControllerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import UIKit
import XCTest
@testable import XmaxSDK

@MainActor
final class RenderControllerTests: XCTestCase {
    func testDisablingInterpolationKeepsFrameDeliveryAndRTCBinding() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")
        try controller.setRemoteStream(stream)
        addTeardownBlock { try await controller.resetRemoteTrack(nil) }
        try rtcManager.emitRemoteVideoFrame()
        try await controller.waitUntilRemoteFrameReady()

        for index in 1...3 {
            try await controller.setFrameInterpolationEnabled(false, videoFormat: nil)
            let recorder = RemoteVideoFrameRecorder()
            try controller.setRemoteMediaFrameListener { event in
                guard case .video(let frame) = event.content else { return }
                recorder.record(frame)
            }
            let timestamp = CMTime(value: Int64(index), timescale: 24)
            try rtcManager.emitRemoteVideoFrame(presentationTimeStamp: timestamp)
            let frame = try await waitForRemoteVideoFrame(recorder)
            XCTAssertEqual(frame.presentationTimeStamp, timestamp)
        }
        XCTAssertEqual(rtcManager.calls, [
            .setRemoteVideoFrameListener(stream, enabled: true),
            .setRemoteAudioFrameListener(stream, enabled: true)
        ])
    }

    func testDisablingInterpolationPreservesPendingFirstFrameWait() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(
            rtcManager: rtcManager,
            frameInterpolationEnabled: true,
            remoteFrameReadyTimeoutNanoseconds: 1000000000
        )
        try controller.setRemoteStream(RemoteStream(roomID: "room-id", userID: "bot-user"))
        addTeardownBlock { try await controller.resetRemoteTrack(nil) }
        let waiting = expectation(description: "Waiting for first remote frame")
        let readiness = Task {
            waiting.fulfill()
            try await controller.waitUntilRemoteFrameReady()
        }
        await fulfillment(of: [waiting], timeout: 2)

        try await controller.setFrameInterpolationEnabled(false, videoFormat: nil)
        try rtcManager.emitRemoteVideoFrame()
        try await readiness.value
    }

    func testSettingStreamBeforeAttachStartsRemoteFrameDelivery() throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")

        try controller.setRemoteStream(stream)

        XCTAssertEqual(
            rtcManager.calls,
            [.setRemoteVideoFrameListener(stream, enabled: true)]
        )
    }

    func testSettingStreamAfterAttachStartsRemoteFrameDelivery() throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let registration = try registerRemoteTrack(with: controller)
        addTeardownBlock { try await controller.resetRemoteTrack(registration.track) }
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")
        let videoView = XmaxRealtimeVideoView()

        try registration.binding.attach(
            to: videoView,
            contentMode: .fit
        )
        try controller.setRemoteStream(stream)

        XCTAssertEqual(
            rtcManager.calls,
            [.setRemoteVideoFrameListener(stream, enabled: true)]
        )
    }

    func testReplacingStreamStopsPreviousAndStartsCurrentFrames() throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let registration = try registerRemoteTrack(with: controller)
        addTeardownBlock { try await controller.resetRemoteTrack(registration.track) }
        let firstStream = RemoteStream(
            roomID: "room-id",
            userID: "first-user"
        )
        let secondStream = RemoteStream(
            roomID: "room-id",
            userID: "second-user"
        )
        let videoView = XmaxRealtimeVideoView()
        try registration.binding.attach(
            to: videoView,
            contentMode: .fill
        )
        try controller.setRemoteStream(firstStream)

        try controller.setRemoteStream(secondStream)

        XCTAssertEqual(
            rtcManager.calls,
            [
                .setRemoteVideoFrameListener(firstStream, enabled: true),
                .setRemoteVideoFrameListener(firstStream, enabled: false),
                .setRemoteVideoFrameListener(secondStream, enabled: true)
            ]
        )
    }

    func testDetachPreservesStreamForLaterAttachment() throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let registration = try registerRemoteTrack(with: controller)
        addTeardownBlock { try await controller.resetRemoteTrack(registration.track) }
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")
        let firstVideoView = XmaxRealtimeVideoView()
        let secondVideoView = XmaxRealtimeVideoView()
        try controller.setRemoteStream(stream)
        try registration.binding.attach(
            to: firstVideoView,
            contentMode: .fit
        )

        try registration.binding.detach()
        try registration.binding.attach(
            to: secondVideoView,
            contentMode: .fill
        )

        XCTAssertEqual(
            rtcManager.calls,
            [.setRemoteVideoFrameListener(stream, enabled: true)]
        )
    }

    func testRemoteFrameReadyWaitsForProcessedFrame() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(
            rtcManager: rtcManager,
            remoteFrameReadyTimeoutNanoseconds: 1_000_000_000
        )
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")
        try controller.setRemoteStream(stream)

        let readiness = Task {
            try await controller.waitUntilRemoteFrameReady()
        }
        try rtcManager.emitRemoteVideoFrame()

        try await readiness.value
    }

    func testRemoteMediaListenerReceivesFinalVideoFrameWithoutView() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let recorder = RemoteVideoFrameRecorder()
        let timestamp = CMTime(value: 42, timescale: 1_000)
        try controller.setRemoteMediaFrameListener { event in
            guard case .video(let frame) = event.content else { return }
            recorder.record(frame)
        }
        try controller.setRemoteStream(
            RemoteStream(roomID: "room-id", userID: "bot-user")
        )

        let pixelBuffer = try rtcManager.emitRemoteVideoFrame(
            presentationTimeStamp: timestamp
        )

        let frame = try await waitForRemoteVideoFrame(recorder)
        XCTAssertTrue(frame.pixelBuffer === pixelBuffer)
        XCTAssertEqual(frame.presentationTimeStamp, timestamp)
        XCTAssertEqual(frame.duration, CMTime(value: 1, timescale: 24))
    }

    func testClearingRemoteMediaListenerStopsVideoDelivery() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let recorder = RemoteVideoFrameRecorder()
        try controller.setRemoteMediaFrameListener { event in
            guard case .video(let frame) = event.content else { return }
            recorder.record(frame)
        }
        try controller.setRemoteMediaFrameListener(nil)
        try controller.setRemoteStream(
            RemoteStream(roomID: "room-id", userID: "bot-user")
        )

        try rtcManager.emitRemoteVideoFrame()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertNil(recorder.firstFrame)
    }

    func testRemoteFrameReadyTimesOutWithoutFrame() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(
            rtcManager: rtcManager,
            remoteFrameReadyTimeoutNanoseconds: 0
        )
        try controller.setRemoteStream(
            RemoteStream(roomID: "room-id", userID: "bot-user")
        )

        do {
            try await controller.waitUntilRemoteFrameReady()
            XCTFail("Expected remote first frame wait to time out")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .timeout)
        }
    }

    func testCancelledRemoteFrameWaitDoesNotReportMissingStream() async {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let readiness = Task {
            try await controller.waitUntilRemoteFrameReady()
        }
        readiness.cancel()

        do {
            try await readiness.value
            XCTFail("Expected remote frame wait to be cancelled")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
    }

    func testUpdatingContentModeDoesNotRegisterRemoteFramesAgain() throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let registration = try registerRemoteTrack(with: controller)
        addTeardownBlock { try await controller.resetRemoteTrack(registration.track) }
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")
        let videoView = XmaxRealtimeVideoView()
        try controller.setRemoteStream(stream)
        try registration.binding.attach(
            to: videoView,
            contentMode: .fit
        )

        try registration.binding.attach(
            to: videoView,
            contentMode: .fill
        )

        XCTAssertEqual(
            rtcManager.calls,
            [.setRemoteVideoFrameListener(stream, enabled: true)]
        )
    }

    func testResetStopsFramesAndClearsStreamAndView() async throws {
        let rtcManager = RtcManagingStub()
        let controller = RenderController(rtcManager: rtcManager)
        let registration = try registerRemoteTrack(with: controller)
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")
        let firstVideoView = XmaxRealtimeVideoView()
        let secondVideoView = XmaxRealtimeVideoView()
        try controller.setRemoteStream(stream)
        try registration.binding.attach(
            to: firstVideoView,
            contentMode: .fit
        )

        try await controller.resetRemoteTrack(registration.track)
        try registration.binding.attach(
            to: secondVideoView,
            contentMode: .fill
        )

        XCTAssertEqual(
            rtcManager.calls,
            [
                .setRemoteVideoFrameListener(stream, enabled: true),
                .setRemoteVideoFrameListener(stream, enabled: false)
            ]
        )
    }

    func testViewAttachmentRetriesFailedFrameBindingAndReportsRTCError() throws {
        let expectedError = XmaxError(
            code: .rtcError,
            message: "Failed to bind the remote RTC frame sink"
        )
        let rtcManager = RtcManagingStub(
            setRemoteVideoFrameListenerError: expectedError
        )
        let recorder = RenderErrorRecorder()
        let controller = RenderController(
            rtcManager: rtcManager,
            errorListener: { recorder.record($0) }
        )
        let registration = try registerRemoteTrack(with: controller)
        addTeardownBlock { try await controller.resetRemoteTrack(registration.track) }
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")
        let videoView = XmaxRealtimeVideoView()
        XCTAssertThrowsError(try controller.setRemoteStream(stream)) { error in
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        XCTAssertTrue(recorder.recordedErrors.isEmpty)

        XCTAssertThrowsError(
            try registration.binding.attach(
                to: videoView,
                contentMode: .fill
            )
        ) { error in
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        XCTAssertEqual(recorder.recordedErrors, [expectedError])
        XCTAssertEqual(
            rtcManager.calls,
            [
                .setRemoteVideoFrameListener(stream, enabled: true),
                .setRemoteVideoFrameListener(stream, enabled: true)
            ]
        )
    }

    func testGenerationFrameBindingFailureIsOnlyThrown() throws {
        let expectedError = XmaxError(
            code: .rtcError,
            message: "Failed to bind the remote RTC frame sink"
        )
        let rtcManager = RtcManagingStub(
            setRemoteVideoFrameListenerError: expectedError
        )
        let recorder = RenderErrorRecorder()
        let controller = RenderController(
            rtcManager: rtcManager,
            errorListener: { recorder.record($0) }
        )
        let registration = try registerRemoteTrack(with: controller)
        addTeardownBlock { try await controller.resetRemoteTrack(registration.track) }
        let videoView = XmaxRealtimeVideoView()
        try registration.binding.attach(
            to: videoView,
            contentMode: .fill
        )
        let stream = RemoteStream(roomID: "room-id", userID: "bot-user")

        XCTAssertThrowsError(try controller.setRemoteStream(stream))
        XCTAssertTrue(recorder.recordedErrors.isEmpty)
    }
}

private final class RenderErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [XmaxError] = []

    var recordedErrors: [XmaxError] {
        lock.withLock { errors }
    }

    func record(_ error: XmaxError) {
        lock.withLock {
            errors.append(error)
        }
    }
}

private final class RemoteVideoFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RealtimeVideoFrame] = []

    var firstFrame: RealtimeVideoFrame? {
        lock.withLock { frames.first }
    }

    func record(_ frame: RealtimeVideoFrame) {
        lock.withLock {
            frames.append(frame)
        }
    }
}

private extension RenderControllerTests {
    func waitForRemoteVideoFrame(
        _ recorder: RemoteVideoFrameRecorder
    ) async throws -> RealtimeVideoFrame {
        for _ in 0..<1_000 {
            if let frame = recorder.firstFrame {
                return frame
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for a remote video frame")
        throw XmaxError(
            code: .timeout,
            message: "Remote video frame callback timed out"
        )
    }

    func registerRemoteTrack(
        with controller: RenderController
    ) throws -> (
        track: RealtimeVideoTrack,
        binding: VideoRenderBinding
    ) {
        let track = RealtimeVideoTrack(
            id: "video-remote",
            videoFormat: RealtimeVideoFormat(
                width: 720,
                height: 1_280,
                fps: 24
            )
        )
        controller.registerRemoteTrack(
            track,
            resolvedMediaSize: CGSize(width: 720, height: 1280),
            interactionListener: { _ in }
        )
        return (
            track,
            try XCTUnwrap(VideoRenderRegistry.binding(for: track))
        )
    }
}
