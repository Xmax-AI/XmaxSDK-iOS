//
//  CameraControllerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import UIKit
import XCTest
@testable import XmaxSDK

final class CameraControllerTests: XCTestCase {
    func testUpdatingFormatPreservesTrackAndAppliesCaptureFrameRate() async throws {
        let capture = CameraCaptureManagingStub()
        let controller = CameraController(
            rtcManager: RtcManagingStub(), permissionManager: PermissionManagingStub(),
            mediaService: MediaService(model: .x2_1_1_preview_cn), captureManager: capture
        )
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeModel.x2_1_1_preview_cn.defaultCameraVideoFormat, position: .back
        )
        try await controller.updateOrientation(.portrait)
        let format = RealtimeVideoFormat(
            width: 1920, height: 1024, fps: 24,
            minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
        )
        try await controller.updateVideoFormat(format)

        XCTAssertTrue(stream.videoTrack === controller.currentTrack)
        XCTAssertEqual(stream.videoTrack?.videoFormat, format)
        XCTAssertEqual(stream.videoTrack?.position, .back)
        XCTAssertEqual(capture.calls.last, .updateFormat(
            try VideoFormat(width: 1920, height: 1024, pixelFormat: .nv12), 24
        ))
        try await controller.updateOrientation(.portrait)
        XCTAssertEqual(stream.videoTrack?.videoFormat, format)
        try await controller.updateOrientation(.landscapeLeft)
        XCTAssertEqual(stream.videoTrack?.videoFormat, format.resized(width: 1024, height: 1920))
        XCTAssertFalse(capture.calls.contains(.stop))
        await controller.stopLocalCameraStream()
    }

    func testUnsupportedUpdatePreservesPreviewWithoutChangingCapture() async throws {
        let capture = CameraCaptureManagingStub()
        let controller = CameraController(
            rtcManager: RtcManagingStub(), permissionManager: PermissionManagingStub(),
            mediaService: MediaService(model: .x2_1_1_preview_cn), captureManager: capture
        )
        let original = RealtimeModel.x2_1_1_preview_cn.defaultCameraVideoFormat
        let stream = try await controller.createLocalCameraStream(videoFormat: original, position: .front)
        let calls = capture.calls
        do {
            try await controller.updateVideoFormat(RealtimeVideoFormat(width: 720, height: 1280, fps: 30))
            XCTFail("Expected unsupported dimensions to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertEqual(stream.videoTrack?.videoFormat, original)
        XCTAssertEqual(capture.calls, calls)
        await controller.stopLocalCameraStream()
    }

    func testFailedCaptureUpdatePreservesTrackFormat() async throws {
        let capture = CameraCaptureManagingStub(updateError: XmaxError(code: .mediaError, message: "Update failed"))
        let controller = CameraController(
            rtcManager: RtcManagingStub(), permissionManager: PermissionManagingStub(),
            mediaService: MediaService(model: .x2_1_1_preview_cn), captureManager: capture
        )
        let original = RealtimeModel.x2_1_1_preview_cn.defaultCameraVideoFormat
        let stream = try await controller.createLocalCameraStream(videoFormat: original, position: .front)
        do {
            try await controller.updateVideoFormat(RealtimeVideoFormat(width: 1920, height: 1024, fps: 30))
            XCTFail("Expected capture update to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertTrue(stream.videoTrack === controller.currentTrack)
        XCTAssertEqual(stream.videoTrack?.videoFormat, original)
        XCTAssertFalse(capture.calls.contains(.stop))
        await controller.stopLocalCameraStream()
    }

    func testCameraOrientationSwapsBucketDimensionsAndPreservesEncodingConfiguration() async throws {
        let capture = CameraCaptureManagingStub()
        let controller = CameraController(
            rtcManager: RtcManagingStub(),
            permissionManager: PermissionManagingStub(),
            mediaService: MediaService(model: .x2_1_1_preview_cn),
            captureManager: capture
        )
        let portrait = RealtimeVideoFormat(
            width: 1024, height: 1920, fps: 30,
            minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
        )
        let stream = try await controller.createLocalCameraStream(videoFormat: portrait, position: .front)
        try await controller.updateOrientation(.portrait)

        for orientation in [CameraOrientation.landscapeLeft, .landscapeRight] {
            try await controller.updateOrientation(orientation)
            XCTAssertEqual(stream.videoTrack?.videoFormat, portrait.resized(width: 1920, height: 1024))
            XCTAssertEqual(
                capture.calls.last,
                .updateOrientation(orientation, try VideoFormat(width: 1920, height: 1024, pixelFormat: .nv12))
            )
        }

        try await controller.updateOrientation(.portrait)
        XCTAssertEqual(stream.videoTrack?.videoFormat, portrait)
        XCTAssertFalse(capture.calls.contains(.stop))
        await controller.stopLocalCameraStream()
    }

    func testBucketCameraPreservesResolutionAndEncodingOptions() async throws {
        for (width, height) in [(1024, 1920), (1920, 1024)] {
            let capture = CameraCaptureManagingStub()
            let controller = CameraController(
                rtcManager: RtcManagingStub(),
                permissionManager: PermissionManagingStub(),
                mediaService: MediaService(model: .x2_1_1_preview_cn),
                captureManager: capture
            )
            let requested = RealtimeVideoFormat(
                width: width, height: height, fps: 30,
                minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
            )
            let stream = try await controller.createLocalCameraStream(videoFormat: requested, position: .front)

            XCTAssertEqual(stream.videoTrack?.videoFormat, requested)
            XCTAssertEqual(capture.calls, [.start(try VideoFormat(width: width, height: height, pixelFormat: .nv12), 30, .front)])
            await controller.stopLocalCameraStream()
        }
    }

    func testUnsupportedBucketCameraFailsBeforePermissionAndCapture() async {
        let capture = CameraCaptureManagingStub()
        let permissions = PermissionManagingStub()
        let rtc = RtcManagingStub()
        let controller = CameraController(
            rtcManager: rtc,
            permissionManager: permissions,
            mediaService: MediaService(model: .x2_1_1_preview_cn),
            captureManager: capture
        )
        do {
            _ = try await controller.createLocalCameraStream(
                videoFormat: RealtimeVideoFormat(width: 832, height: 1472, fps: 24), position: .front
            )
            XCTFail("Expected unsupported resolution to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }

        XCTAssertEqual(permissions.cameraRequestCount, 0)
        XCTAssertTrue(capture.calls.isEmpty)
        XCTAssertTrue(rtc.calls.isEmpty)
        XCTAssertNil(controller.currentTrack)
    }

    func testCameraPreservesEncodingOptionsAfterSizeResolution() async throws {
        let capture = CameraCaptureManagingStub()
        let rtc = RtcManagingStub()
        let controller = CameraController(
            rtcManager: rtc,
            permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 896, height: 672)),
            captureManager: capture
        )
        let requested = RealtimeVideoFormat(
            width: 640, height: 480, fps: 25,
            minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
        )
        let stream = try await controller.createLocalCameraStream(videoFormat: requested, position: .front)
        XCTAssertEqual(stream.videoTrack?.videoFormat, RealtimeVideoFormat(
            width: 896, height: 672, fps: 25,
            minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
        ))
        XCTAssertEqual(capture.calls, [.start(try VideoFormat(width: 896, height: 672, pixelFormat: .nv12), 25, .front)])
        XCTAssertEqual(rtc.calls, [.useExternalVideoSource, .configureLocalVideoMirror(.front)])
        await controller.stopLocalCameraStream()
    }

    func testCreateStartsSystemCaptureAndRegistersLocalTrack() async throws {
        let rtc = RtcManagingStub()
        let capture = CameraCaptureManagingStub()
        let permissions = PermissionManagingStub()
        let controller = makeManager(rtcManager: rtc, permissionManager: permissions, captureManager: capture)
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .front
        )
        XCTAssertEqual(permissions.cameraRequestCount, 1)
        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        XCTAssertFalse(controller.useMicrophone)
        XCTAssertEqual(stream.id, StreamID.local.rawValue)
        XCTAssertEqual(stream.videoTrack?.id, "video0")
        XCTAssertEqual(stream.videoTrack?.position, .front)
        XCTAssertTrue(stream.videoTrack === controller.currentTrack)
        let track = try XCTUnwrap(stream.videoTrack)
        let hasBinding = await MainActor.run { VideoRenderRegistry.binding(for: track) != nil }
        XCTAssertTrue(hasBinding)
        XCTAssertEqual(rtc.calls, [.useExternalVideoSource, .configureLocalVideoMirror(.front)])
        await controller.stopLocalCameraStream()
    }

    func testCreateRejectsSecondActiveCameraStream() async throws {
        let capture = CameraCaptureManagingStub()
        let controller = makeManager(captureManager: capture)
        _ = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .front
        )
        do {
            _ = try await controller.createLocalCameraStream(
                videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .back
            )
            XCTFail("Expected duplicate stream to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertEqual(capture.calls.count, 1)
        await controller.stopLocalCameraStream()
    }

    func testCreateRollsBackWhenSystemCaptureFails() async {
        let error = XmaxError(code: .mediaError, message: "Capture failed")
        let capture = CameraCaptureManagingStub(startError: error)
        let controller = makeManager(captureManager: capture)
        do {
            _ = try await controller.createLocalCameraStream(
                videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .front
            )
            XCTFail("Expected capture failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertNil(controller.currentTrack)
        XCTAssertEqual(capture.calls.last, .stop)
    }

    func testSwitchCameraPreservesTrackAndUpdatesMirror() async throws {
        let capture = CameraCaptureManagingStub()
        let rtc = RtcManagingStub()
        let controller = makeManager(rtcManager: rtc, captureManager: capture)
        let original = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .front
        )
        let switched = try await controller.switchCamera()
        XCTAssertTrue(original.videoTrack === switched.videoTrack)
        XCTAssertEqual(switched.videoTrack?.position, .back)
        XCTAssertEqual(capture.calls.last, .switchCamera(.back))
        XCTAssertEqual(rtc.calls.last, .configureLocalVideoMirror(.back))
        await controller.stopLocalCameraStream()
    }

    func testFailedCameraSwitchPreservesTrackPosition() async throws {
        let capture = CameraCaptureManagingStub(switchError: XmaxError(code: .mediaError, message: "Switch failed"))
        let rtc = RtcManagingStub()
        let controller = makeManager(rtcManager: rtc, captureManager: capture)
        let original = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .front
        )
        do {
            _ = try await controller.switchCamera()
            XCTFail("Expected switch failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertEqual(original.videoTrack?.position, .front)
        XCTAssertEqual(rtc.calls.last, .configureLocalVideoMirror(.front))
        await controller.stopLocalCameraStream()
    }

    @MainActor
    func testPreviewUsesSDKRendererAndStopDropsLateFrames() async throws {
        let capture = CameraCaptureManagingStub()
        let rtc = RtcManagingStub()
        let recorder = CameraFrameRecorder()
        let controller = makeManager(
            rtcManager: rtc, captureManager: capture,
            videoFrameListener: { recorder.append($0) }
        )
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .front
        )
        let track = try XCTUnwrap(stream.videoTrack)
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
        let view = XmaxRealtimeVideoView()
        let ready = expectation(description: "Camera preview ready")
        var previewIsCurrent: (@Sendable () -> Bool)?
        controller.setPreviewReadyHandler { isCurrent in
            previewIsCurrent = isCurrent
            ready.fulfill()
        }
        try binding.attach(to: view, contentMode: .fit)
        let frame = try Self.testFrame()
        let lateListener = capture.currentFrameListener
        try capture.emitFrame(frame)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(recorder.frames, [frame])
        XCTAssertEqual(previewIsCurrent?(), true)

        await controller.stopLocalCameraStream()
        XCTAssertEqual(previewIsCurrent?(), false)
        try lateListener?(frame)
        XCTAssertEqual(recorder.frames, [frame])
        XCTAssertNil(controller.currentTrack)
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
        XCTAssertEqual(capture.calls.last, .stop)
    }

    @MainActor
    func testCameraFramesUploadWithIndicesOnlyDuringGeneration() async throws {
        let rtc = RtcManagingStub()
        let capture = CameraCaptureManagingStub()
        let streamController = StreamController(rtcManager: rtc)
        try streamController.configureRoom(roomID: "room", botName: "bot")
        let controller = makeManager(
            rtcManager: rtc, captureManager: capture,
            videoFrameListener: { try streamController.pushLocalVideoFrame($0) }
        )
        _ = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 30), position: .front
        )
        let frame = try Self.testFrame()
        try capture.emitFrame(frame)
        let taskID = XmaxRealtimeGenerationManager.createTaskID()
        try await streamController.connect(connection: RealtimeSessionConnection(
            roomID: "room", userID: "user", token: "token", botName: "bot"
        ), includeLocalAudio: false, ensureActive: {})
        let confirmation = try await streamController.beginGeneration(
            taskID: taskID, videoFormat: RealtimeVideoFormat(width: 1024, height: 1920, fps: 30),
            context: RealtimeContext(prompt: "test")
        )
        try capture.emitFrame(frame)
        try capture.emitFrame(frame.updating(timestampUs: frame.timestampUs + 33333))
        rtc.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room", userID: "bot"))
        try await confirmation.value
        _ = await streamController.stopStreamGeneration(taskID: taskID)
        try capture.emitFrame(frame)
        XCTAssertEqual(rtc.calls.filter { $0 == .pushExternalVideoFrame }.count, 2)
        XCTAssertFalse(capture.calls.contains(.stop))
        await controller.stopLocalCameraStream()
    }

    static func testFrame() throws -> VideoFrame {
        try VideoFrame(
            format: VideoFormat(width: 2, height: 2, pixelFormat: .nv12),
            timestampUs: 123456,
            planes: [
                VideoFramePlane(data: Data(repeating: 16, count: 4), stride: 2),
                VideoFramePlane(data: Data(repeating: 128, count: 2), stride: 2)
            ]
        )
    }
}

extension CameraControllerTests {
    func testMicrophonePermissionDoesNotStartCaptureDuringPreview() async throws {
        let rtcManager = RtcManagingStub()
        let permissions = PermissionManagingStub()
        let controller = makeManager(
            rtcManager: rtcManager,
            permissionManager: permissions
        )
        _ = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 24),
            position: .front,
            useMicrophone: true
        )

        XCTAssertEqual(permissions.microphoneRequestCount, 1)
        XCTAssertTrue(controller.useMicrophone)
        XCTAssertFalse(rtcManager.calls.contains(.startAudioCapture))
        await controller.stopLocalCameraStream()
        XCTAssertFalse(controller.useMicrophone)
        XCTAssertFalse(rtcManager.calls.contains(.stopAudioCapture))
    }

    func testDeniedMicrophonePermissionDoesNotStartCameraOrAudio() async {
        let expectedError = XmaxError(
            code: .microphonePermissionDenied,
            message: "Microphone access denied"
        )
        let rtcManager = RtcManagingStub()
        let controller = makeManager(
            rtcManager: rtcManager,
            permissionManager: PermissionManagingStub(microphoneError: expectedError)
        )
        do {
            _ = try await controller.createLocalCameraStream(
                videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 24),
                position: .front,
                useMicrophone: true
            )
            XCTFail("Expected microphone permission to be denied")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        XCTAssertNil(controller.currentTrack)
        XCTAssertFalse(controller.useMicrophone)
        XCTAssertTrue(rtcManager.calls.isEmpty)
    }

    func testMicrophoneCaptureIsIdempotentAndCameraStopReleasesIt() async throws {
        let rtcManager = RtcManagingStub()
        let controller = makeManager(rtcManager: rtcManager)
        _ = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1024, height: 768, fps: 24),
            position: .front,
            useMicrophone: true
        )
        try controller.startMicrophoneCapture()
        try controller.startMicrophoneCapture()
        try controller.stopMicrophoneCapture()
        try controller.stopMicrophoneCapture()
        try controller.startMicrophoneCapture()
        _ = try await controller.switchCamera()
        await controller.stopLocalCameraStream()

        XCTAssertEqual(
            rtcManager.calls.filter { $0 == .startAudioCapture || $0 == .stopAudioCapture },
            [.startAudioCapture, .stopAudioCapture, .startAudioCapture, .stopAudioCapture]
        )
    }
}

private extension CameraControllerTests {
    func makeManager(
        rtcManager: RtcManagingStub = RtcManagingStub(),
        permissionManager: PermissionManagingStub = PermissionManagingStub(),
        mediaService: MediaServicingStub = MediaServicingStub(
            resolvedSize: CGSize(width: 1_024, height: 768)
        ),
        captureManager: CameraCaptureManagingStub = CameraCaptureManagingStub(),
        videoFrameListener: @escaping MediaVideoFrameListener = { _ in },
        errorListener: @escaping XmaxErrorListener = { _ in }
    ) -> CameraController {
        CameraController(
            rtcManager: rtcManager,
            permissionManager: permissionManager,
            mediaService: mediaService,
            captureManager: captureManager,
            videoFrameListener: videoFrameListener,
            errorListener: errorListener
        )
    }
}

private final class CameraFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VideoFrame] = []

    var frames: [VideoFrame] {
        lock.withLock { values }
    }

    func append(_ frame: VideoFrame) {
        lock.withLock {
            values.append(frame)
        }
    }
}
