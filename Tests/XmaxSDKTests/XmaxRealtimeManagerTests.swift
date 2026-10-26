//
//  XmaxRealtimeManagerTests.swift
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
import CoreMedia
import XCTest
@testable import XmaxSDK

private extension XmaxRealtimeConnectionManager {
    func holdQueries(
        gate: DispatchSemaphore,
        entered: @Sendable () -> Void
    ) -> Bool {
        entered()
        return gate.wait(timeout: .now() + 5) == .success
    }
}

private extension XmaxRealtimeManager {
    func startGenerationDuringPreparationTest(
        localStream: RealtimeMediaStream?,
        entered: @Sendable () -> Void
    ) async throws {
        entered()
        let context = RealtimeContext(prompt: "video")
        if let localStream {
            _ = try await startGeneration(localStream: localStream, context: context)
        } else {
            try await startGeneration(context: context)
        }
    }
}

@MainActor
final class XmaxRealtimeManagerTests: XCTestCase {
    private var qualityHistorySuites: [String] = []

    override func tearDown() async throws {
        await MainActor.run {
            for name in qualityHistorySuites {
                UserDefaults.standard.removePersistentDomain(forName: name)
            }
            qualityHistorySuites = []
        }
        try await super.tearDown()
    }

    func testManualQualityIsUnavailableBeforeGenerationAndClearedAfterDisconnect() async throws {
        let components = makeComponents()
        var uplink = await components.manager.uplinkQualityLevel
        var downlink = await components.manager.downlinkQualityLevel
        XCTAssertNil(uplink)
        XCTAssertNil(downlink)
        do {
            try await components.manager.setUplinkQualityLevel(.l3)
            XCTFail("Expected rejection before connection")
        } catch {
            XCTAssertEqual(XmaxError.from(error).code, .invalidConfiguration)
        }

        let local = try await components.manager.createLocalImageStream(fileURL: URL(fileURLWithPath: "/tmp/image.png"))
        _ = try await components.manager.connect(localStream: local)
        uplink = await components.manager.uplinkQualityLevel
        downlink = await components.manager.downlinkQualityLevel
        XCTAssertEqual(uplink, .l1)
        XCTAssertEqual(downlink, .l1)
        do {
            try await components.manager.setDownlinkQualityLevel(.l3)
            XCTFail("Expected rejection before generation")
        } catch {
            XCTAssertEqual(XmaxError.from(error).code, .invalidConfiguration)
        }
        await components.manager.disconnect()
        uplink = await components.manager.uplinkQualityLevel
        downlink = await components.manager.downlinkQualityLevel
        XCTAssertNil(uplink)
        XCTAssertNil(downlink)
        await components.manager.close()
    }

    func testManualQualityUsesSharedSizingAndKeepsGenerationActive() async throws {
        let components = makeComponents(frameInterpolationSupported: true)
        let local = try await components.manager.createLocalImageStream(fileURL: URL(fileURLWithPath: "/tmp/image.png"))
        _ = try await components.manager.connect(localStream: local)
        let start = Task { try await components.manager.startGeneration(context: RealtimeContext(prompt: "test")) }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
        try components.rtcManager.emitRemoteVideoFrame()
        try await start.value
        let originalState = await components.manager.currentState

        try await components.manager.setUplinkQualityLevel(.l3)
        let uplink = await components.manager.uplinkQualityLevel
        let unchangedDownlink = await components.manager.downlinkQualityLevel
        XCTAssertEqual(uplink, .l3)
        XCTAssertEqual(unchangedDownlink, .l1)
        let expectedUplink = QualityVideoFormat.resolve(imageFormat, level: .l3, downlink: false)
        XCTAssertEqual(components.rtcManager.encodingConfigurations.last?.width, expectedUplink.width)
        XCTAssertEqual(components.rtcManager.encodingConfigurations.last?.height, expectedUplink.height)

        try await components.manager.setFrameInterpolationEnabled(true)
        try await components.manager.setDownlinkQualityLevel(.l3)
        let downlink = await components.manager.downlinkQualityLevel
        let target = await components.connectionManager.currentTargetSize
        let expectedTarget = try MediaService().resolveTargetSize(
            imageFormat.size,
            maximumSize: QualityVideoFormat.resolveDownlinkMaximumSize(imageFormat, level: .l3),
            frameInterpolationEnabled: true
        )
        XCTAssertEqual(downlink, .l3)
        XCTAssertEqual(target, expectedTarget)
        XCTAssertEqual(local.videoTrack?.videoFormat, imageFormat)
        let current = await components.manager.currentState
        XCTAssertEqual(current, originalState)
        XCTAssertEqual(decodedEvents(components.rtcManager).filter { $0["event"] as? String == "start" }.count, 1)
        await components.manager.close()
    }

    func testFailedManualDownlinkKeepsCurrentLevelAndConnection() async throws {
        let components = makeComponents()
        let local = try await components.manager.createLocalImageStream(fileURL: URL(fileURLWithPath: "/tmp/image.png"))
        _ = try await components.manager.connect(localStream: local)
        let start = Task { try await components.manager.startGeneration(context: RealtimeContext(prompt: "test")) }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
        try components.rtcManager.emitRemoteVideoFrame()
        try await start.value
        let originalState = await components.manager.currentState
        let originalTarget = await components.connectionManager.currentTargetSize
        components.rtcManager.setSendRoomMessageError(XmaxError(code: .rtcError, message: "send failed"))
        do {
            try await components.manager.setDownlinkQualityLevel(.l4)
            XCTFail("Expected signaling failure")
        } catch {
            XCTAssertEqual(XmaxError.from(error).code, .rtcError)
        }
        let downlink = await components.manager.downlinkQualityLevel
        let target = await components.connectionManager.currentTargetSize
        let state = await components.manager.currentState
        XCTAssertEqual(downlink, .l1)
        XCTAssertEqual(target, originalTarget)
        XCTAssertEqual(state, originalState)
        components.rtcManager.setSendRoomMessageError(nil)
        await components.manager.close()
    }

    func testDisabledAdaptationKeepsStatisticsManualQualityAndInterpolationAvailable() async throws {
        let components = makeComponents(
            frameInterpolationEnabled: true,
            frameInterpolationSupported: true,
            initialQualityLevel: .l4,
            isAdaptiveQualityEnabled: false
        )
        let local = try await components.manager.createLocalImageStream(fileURL: URL(fileURLWithPath: "/tmp/image.png"))
        _ = try await components.manager.connect(localStream: local)
        let initialUplink = await components.manager.uplinkQualityLevel
        let initialDownlink = await components.manager.downlinkQualityLevel
        XCTAssertEqual(initialUplink, .l1)
        XCTAssertEqual(initialDownlink, .l1)
        let target = await components.connectionManager.currentTargetSize
        let expectedTarget = try MediaService().resolveTargetSize(
            imageFormat.size,
            maximumSize: imageFormat.size,
            frameInterpolationEnabled: true
        )
        XCTAssertEqual(target, expectedTarget)

        let start = Task { try await components.manager.startGeneration(context: RealtimeContext(prompt: "test")) }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
        try components.rtcManager.emitRemoteVideoFrame()
        try await start.value

        var receivedQuality: RealtimeNetworkQuality?
        await components.manager.setNetworkQualityListener { receivedQuality = $0 }
        for _ in 0..<10 {
            components.rtcManager.emitNetworkQuality(uplink: .bad, downlink: .bad)
            await Task.yield()
        }
        XCTAssertEqual(receivedQuality, RealtimeNetworkQuality(uplink: .bad, downlink: .bad))
        let unchangedUplink = await components.manager.uplinkQualityLevel
        let unchangedDownlink = await components.manager.downlinkQualityLevel
        XCTAssertEqual(unchangedUplink, .l1)
        XCTAssertEqual(unchangedDownlink, .l1)

        try await components.manager.setUplinkQualityLevel(.l3)
        try await components.manager.setDownlinkQualityLevel(.l4)
        let manualUplink = await components.manager.uplinkQualityLevel
        let manualDownlink = await components.manager.downlinkQualityLevel
        XCTAssertEqual(manualUplink, .l3)
        XCTAssertEqual(manualDownlink, .l4)
        await components.manager.disconnect()
        _ = try await components.manager.connect(localStream: local)
        let reconnectedUplink = await components.manager.uplinkQualityLevel
        let reconnectedDownlink = await components.manager.downlinkQualityLevel
        XCTAssertEqual(reconnectedUplink, .l1)
        XCTAssertEqual(reconnectedDownlink, .l1)
        await components.manager.close()
    }

    func testQualityAndInterpolationShareReturnSizeWithoutChangingMediaOrGenerationCanvas() async throws {
        for level in [RealtimeQualityLevel.l1, .l2, .l4] {
            let components = makeComponents(frameInterpolationSupported: true, initialQualityLevel: level)
            let local = try await components.manager.createLocalImageStream(fileURL: URL(fileURLWithPath: "/tmp/image.png"))
            _ = try await components.manager.connect(localStream: local)
            let start = Task { try await components.manager.startGeneration(context: RealtimeContext(prompt: "test")) }
            await waitForEvent("start", rtcManager: components.rtcManager)
            components.rtcManager.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
            try components.rtcManager.emitRemoteVideoFrame()
            try await start.value
            let originalState = await components.manager.currentState
            let networkTarget = try MediaService().resolveTargetSize(
                imageFormat.size,
                maximumSize: QualityVideoFormat.resolveDownlinkMaximumSize(imageFormat, level: level),
                frameInterpolationEnabled: false
            )

            try await components.manager.setFrameInterpolationEnabled(true)
            var target = await components.connectionManager.currentTargetSize
            let interpolationTarget = level == .l1 ? CGSize(width: 676, height: 1196) : networkTarget
            XCTAssertEqual(target, interpolationTarget)

            try await components.manager.setFrameInterpolationEnabled(false)
            target = await components.connectionManager.currentTargetSize
            XCTAssertEqual(target, networkTarget)
            let sizeChanges = decodedEvents(components.rtcManager).filter { $0["event"] as? String == "change_target_size" }
            XCTAssertEqual(sizeChanges.count, level == .l1 ? 2 : 0)

            XCTAssertEqual(local.videoTrack?.videoFormat, imageFormat)
            let current = await components.manager.currentState
            XCTAssertEqual(current, originalState)
            XCTAssertEqual(decodedEvents(components.rtcManager).filter { $0["event"] as? String == "start" }.count, 1)
            await components.manager.close()
        }
    }

    func testRejectedCameraCreationOnlyThrowsWithoutFailureState() async throws {
        let failure = XmaxError(code: .cameraPermissionDenied, message: "Camera permission denied")
        let components = makeComponents(captureManager: CameraCaptureManagingStub(startError: failure))
        var states: [RealtimeState] = []
        await components.manager.setStateListener { states.append($0) }
        do {
            _ = try await components.manager.createLocalCameraStream()
            XCTFail("Expected creation failure")
        } catch {
            XCTAssertEqual(error as? XmaxError, failure)
        }
        XCTAssertEqual(states, [RealtimeConnectionState.idle, .preparing, .idle].map {
            RealtimeState(connectionState: $0)
        })
        await components.manager.close()
    }

    func testDuplicateCreationDoesNotDestroyCurrentPreview() async throws {
        let components = makeComponents()
        let local = try await components.manager.createLocalCameraStream()
        do {
            _ = try await components.manager.createLocalCameraStream()
            XCTFail("Expected duplicate creation to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        let ownsLocal = await components.mediaController.owns(local)
        let state = await components.manager.currentState
        XCTAssertTrue(ownsLocal)
        XCTAssertEqual(state, RealtimeState(connectionState: .preparing))
        XCTAssertFalse(components.captureManager.calls.contains(.stop))
        await components.manager.close()
    }

    func testCameraRuntimeFailureReleasesMediaWithAndWithoutSession() async throws {
        for connects in [false, true] {
            let components = makeComponents()
            let local = try await components.manager.createLocalCameraStream()
            if connects { _ = try await components.manager.connect(localStream: local) }
            let failure = XmaxError(code: .mediaError, message: "Capture terminated")
            let ended = expectation(description: "Media failure cleanup finished")
            await components.manager.setStateListener { state in
                if state.connectionState == .idle, state.reason == .failure(failure) {
                    ended.fulfill()
                }
            }
            components.captureManager.emitError(failure)
            await fulfillment(of: [ended], timeout: 3)
            let track = await components.mediaController.currentTrack
            XCTAssertNil(track)
            XCTAssertEqual(components.captureManager.calls.filter { $0 == .stop }.count, 1)
            XCTAssertEqual(components.sessionService.calls.filter {
                $0 == .closeSession("session-id")
            }.count, connects ? 1 : 0)
            await components.manager.setStateListener(nil)
            await components.manager.close()
        }
    }

    func testOldCameraFailureDoesNotStopReplacementPreview() async throws {
        let components = makeComponents()
        _ = try await components.manager.createLocalCameraStream()
        let oldListener = components.captureManager.currentErrorListener
        try await components.manager.stopLocalCameraStream()
        let replacement = try await components.manager.createLocalCameraStream()
        oldListener?(XmaxError(code: .mediaError, message: "Old capture failed"))
        for _ in 0..<20 { await Task.yield() }
        let state = await components.manager.currentState
        let ownsReplacement = await components.mediaController.owns(replacement)
        XCTAssertEqual(state, RealtimeState(connectionState: .preparing))
        XCTAssertTrue(ownsReplacement)
        await components.manager.close()
    }

    func testStartSignalFailureClosesSessionAndPreservesPreview() async throws {
        for connectFirst in [false, true] {
            let components = makeComponents()
            let local = try await components.manager.createLocalCameraStream()
            if connectFirst { _ = try await components.manager.connect(localStream: local) }
            let failure = XmaxError(code: .rtcError, message: "Start signal failed")
            components.rtcManager.setSendRoomMessageError(failure)
            do {
                if connectFirst {
                    try await components.manager.startGeneration(context: RealtimeContext(prompt: "test"))
                } else {
                    _ = try await components.manager.startGeneration(
                        localStream: local, context: RealtimeContext(prompt: "test")
                    )
                }
                XCTFail("Expected start failure")
            } catch {
                XCTAssertEqual(error as? XmaxError, failure)
            }
            let state = await components.manager.currentState
            let ownsLocal = await components.mediaController.owns(local)
            XCTAssertEqual(state.connectionState, .ready)
            XCTAssertEqual(state.reason, .failure(failure))
            XCTAssertTrue(ownsLocal)
            XCTAssertEqual(components.sessionService.calls.filter {
                $0 == .closeSession("session-id")
            }.count, 1)
            await components.manager.close()
        }
    }

    func testMissingContextDoesNotCreateSessionOrDisturbPreview() async throws {
        let components = makeComponents()
        let local = try await components.manager.createLocalCameraStream()
        do {
            _ = try await components.manager.startGeneration(localStream: local, context: nil)
            XCTFail("Expected missing context")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        let state = await components.manager.currentState
        XCTAssertEqual(state, RealtimeState(connectionState: .preparing))
        XCTAssertTrue(components.sessionService.calls.isEmpty)
        await components.manager.close()
    }

    func testCancelledConditionUpdatesPreserveActiveGenerationForBothEntryPoints() async throws {
        let components = makeComponents()
        let local = try await components.manager.createLocalImageStream(
            fileURL: URL(fileURLWithPath: "/tmp/reference.png")
        )
        _ = try await components.manager.connect(localStream: local)
        let starting = Task {
            try await components.manager.startGeneration(context: RealtimeContext(prompt: "first"))
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let start = try XCTUnwrap(decodedEvents(components.rtcManager).first {
            $0["event"] as? String == "start"
        })
        let taskID = try XCTUnwrap(start["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
        try components.rtcManager.emitRemoteVideoFrame()
        try await starting.value
        let previousState = await components.manager.currentState

        for includesLocalStream in [false, true] {
            components.rtcManager.setSendRoomMessageError(
                XmaxError(code: .cancelled, message: "Condition update cancelled")
            )
            do {
                let context = RealtimeContext(prompt: "cancelled update")
                if includesLocalStream {
                    _ = try await components.manager.startGeneration(localStream: local, context: context)
                } else {
                    try await components.manager.startGeneration(context: context)
                }
                XCTFail("Expected condition update cancellation")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
            }
            let current = await components.manager.currentState
            XCTAssertEqual(current, previousState)
            XCTAssertFalse(decodedEvents(components.rtcManager).contains {
                $0["event"] as? String == "stop"
            })
            components.rtcManager.setSendRoomMessageError(nil)
        }
        try await components.manager.startGeneration(context: RealtimeContext(prompt: "retry"))
        XCTAssertEqual(decodedEvents(components.rtcManager).filter {
            $0["event"] as? String == "start"
        }.count, 1)
        await components.manager.close()
    }

    func testTargetSizeSignalingFailurePreservesInterpolationAndGeneration() async throws {
        let components = makeComponents(frameInterpolationSupported: true)
        let local = try await components.manager.createLocalImageStream(
            fileURL: URL(fileURLWithPath: "/tmp/reference.png")
        )
        let remote = try await components.manager.connect(localStream: local)
        let starting = Task {
            try await components.manager.startGeneration(context: RealtimeContext(prompt: "first"))
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let start = try XCTUnwrap(decodedEvents(components.rtcManager).first {
            $0["event"] as? String == "start"
        })
        let taskID = try XCTUnwrap(start["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
        try components.rtcManager.emitRemoteVideoFrame()
        try await starting.value
        let state = await components.manager.currentState

        for enabled in [true, false] {
            let previousTarget = await components.connectionManager.currentTargetSize
            let previousFormat = remote.videoTrack?.videoFormat
            components.rtcManager.setSendRoomMessageError(XmaxError(code: .rtcError, message: "send failed"))
            do {
                try await components.manager.setFrameInterpolationEnabled(enabled)
                XCTFail("Expected signaling failure")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .rtcError)
            }
            let current = await components.manager.currentState
            let interpolationEnabled = await components.manager.isFrameInterpolationEnabled
            let target = await components.connectionManager.currentTargetSize
            XCTAssertEqual(current, state)
            XCTAssertEqual(interpolationEnabled, !enabled)
            XCTAssertEqual(target, previousTarget)
            XCTAssertEqual(remote.videoTrack?.videoFormat, previousFormat)
            components.rtcManager.setSendRoomMessageError(nil)
            try await components.manager.setFrameInterpolationEnabled(enabled)
        }
        await components.manager.close()
    }

    func testInterpolationBeforeGenerationUpdatesNextStartWithoutResizeEvent() async throws {
        let components = makeComponents(frameInterpolationSupported: true)
        let local = try await components.manager.createLocalImageStream(
            fileURL: URL(fileURLWithPath: "/tmp/reference.png")
        )
        try await components.manager.setFrameInterpolationEnabled(true)
        let remote = try await components.manager.connect(localStream: local)
        XCTAssertEqual(remote.videoTrack?.videoFormat?.size, CGSize(width: 676, height: 1196))
        try await components.manager.setFrameInterpolationEnabled(false)
        XCTAssertEqual(remote.videoTrack?.videoFormat, imageFormat)
        let target = await components.connectionManager.currentTargetSize
        XCTAssertEqual(target, imageFormat.size)
        XCTAssertFalse(decodedEvents(components.rtcManager).contains {
            $0["event"] as? String == "change_target_size"
        })
        await components.manager.close()
    }

    func testImageGenerationSelectsModelCanvasBeforeDecidingPadding() async throws {
        let cases: [(CGSize, CGSize, Bool)] = [
            (CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1920), false),
            (CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080), false),
            (CGSize(width: 1408, height: 1408), CGSize(width: 1408, height: 1408), false),
            (CGSize(width: 1152, height: 1536), CGSize(width: 1152, height: 1536), false),
            (CGSize(width: 1536, height: 1152), CGSize(width: 1536, height: 1152), false),
            (CGSize(width: 1200, height: 1600), CGSize(width: 1152, height: 1536), false),
            (CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080), false),
            (CGSize(width: 1200, height: 1500), CGSize(width: 1152, height: 1536), true),
            (CGSize(width: 1156, height: 1536), CGSize(width: 1152, height: 1536), true),
            (CGSize(width: 1024, height: 1920), CGSize(width: 1080, height: 1920), true)
        ]
        for (mediaSize, canvasSize, contain) in cases {
            let components = makeComponents(
                imageVideoFormat: RealtimeVideoFormat(
                    width: Int(mediaSize.width),
                    height: Int(mediaSize.height),
                    fps: 30
                )
            )
            let local = try await components.manager.createLocalImageStream(
                fileURL: URL(fileURLWithPath: "/tmp/reference.png")
            )
            try await assertGenerationPadding(
                components: components,
                localStream: local,
                canvasSize: canvasSize,
                contain: contain
            )
        }
    }

    func testCameraVideoAndExternalGenerationUseTheSamePaddingRule() async throws {
        for source: RealtimeMediaSource in [.camera, .video, .external] {
            let components = makeComponents(cameraMediaService: MediaService())
            let local: RealtimeMediaStream
            let canvasSize: CGSize
            let contain: Bool
            switch source {
            case .camera:
                local = try await components.manager.createLocalCameraStream(
                    videoFormat: RealtimeModel.x2_1.defaultCameraVideoFormat,
                    position: .front
                )
                canvasSize = CGSize(width: 1080, height: 1920)
                contain = false
            case .video:
                local = try await components.manager.createLocalVideoStream(
                    fileURL: URL(fileURLWithPath: "/tmp/video.mp4")
                )
                canvasSize = CGSize(width: 1080, height: 1920)
                contain = true
            case .external:
                local = try await components.manager.createExternalVideoStream(
                    source: RealtimeExternalVideoSourceStub()
                )
                canvasSize = CGSize(width: 1920, height: 1080)
                contain = false
            case .image:
                XCTFail("Images are covered separately")
                continue
            }
            try await assertGenerationPadding(
                components: components,
                localStream: local,
                canvasSize: canvasSize,
                contain: contain
            )
        }
    }

    func testRuntimeInterpolationChangesTargetSizeWithoutRestartingGeneration() async throws {
        let components = makeComponents(
            frameInterpolationSupported: true
        )
        let local = try await components.manager.createLocalImageStream(
            fileURL: URL(fileURLWithPath: "/tmp/reference.png")
        )
        let remote = try await components.manager.connect(localStream: local)
        let targetFormat = RealtimeVideoFormat(width: 676, height: 1196, fps: 24)
        XCTAssertEqual(local.videoTrack?.videoFormat, imageFormat)
        XCTAssertEqual(remote.videoTrack?.videoFormat, imageFormat)

        let startTask = Task {
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "first")
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let start = try XCTUnwrap(decodedEvents(components.rtcManager).first {
            $0["event"] as? String == "start"
        })
        let taskID = try XCTUnwrap(start["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(roomID: "room-id", userID: "bot-user"))
        try components.rtcManager.emitRemoteVideoFrame()
        try await startTask.value
        let beforeToggle = await components.manager.currentState
        let mutedIndex = try XCTUnwrap(components.rtcManager.calls.firstIndex(
            of: .setRemoteAudioVolume(0, userID: "bot-user")
        ))
        let audioSubscriptionIndex = try XCTUnwrap(components.rtcManager.calls.firstIndex(
            of: .subscribeRemoteAudio(userID: "bot-user", subscribe: true)
        ))
        XCTAssertLessThan(mutedIndex, audioSubscriptionIndex)
        let encodingBeforeToggle = components.rtcManager.encodingConfigurations
        XCTAssertEqual(
            encodingBeforeToggle.last,
            VideoEncodingConfiguration(
                width: 832,
                height: 1472,
                frameRate: 24,
                minimumBitrate: 500,
                maximumBitrate: 2166
            )
        )
        try await components.manager.setFrameInterpolationEnabled(true)
        try await components.manager.startGeneration(context: RealtimeContext(prompt: "second"))
        let change = try XCTUnwrap(decodedEvents(components.rtcManager).last {
            $0["event"] as? String == "change_condition"
        })
        let startParams = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual(startParams["size"] as? [Int], [1024, 1920])
        XCTAssertEqual(startParams["target_size"] as? [Int], [832, 1472])
        XCTAssertEqual(startParams["padding"] as? String, "contain")
        let changeParams = try XCTUnwrap(change["params"] as? [String: Any])
        XCTAssertEqual(changeParams["size"] as? [Int], [1024, 1920])
        XCTAssertNil(changeParams["target_size"])
        XCTAssertEqual(remote.videoTrack?.videoFormat, targetFormat)
        await components.mediaController.submitInteraction(InteractionFrame(
            points: [CGPoint(x: 50, y: 50)],
            viewportSize: CGSize(width: 100, height: 100),
            contentMode: .fit
        ))
        await waitForEvent("tracks", rtcManager: components.rtcManager)
        let tracks = try XCTUnwrap(decodedEvents(components.rtcManager).last {
            $0["event"] as? String == "tracks"
        })
        XCTAssertEqual(tracks["tracks"] as? [[Double]], [[0.5, 0.5]])

        try await components.manager.setFrameInterpolationEnabled(false)
        XCTAssertEqual(remote.videoTrack?.videoFormat, imageFormat)
        try await components.manager.setFrameInterpolationEnabled(true)
        XCTAssertEqual(remote.videoTrack?.videoFormat, targetFormat)
        try await components.manager.setFrameInterpolationEnabled(false)
        let events = decodedEvents(components.rtcManager)
        let resizeEvents = events.filter { $0["event"] as? String == "change_target_size" }
        XCTAssertEqual(resizeEvents.count, 4)
        for (event, size) in zip(resizeEvents, [[676, 1196], [832, 1472], [676, 1196], [832, 1472]]) {
            XCTAssertEqual(event["uid"] as? String, taskID)
            let params = try XCTUnwrap(event["params"] as? [String: Any])
            XCTAssertEqual(params["target_size"] as? [Int], size)
        }
        let afterToggle = await components.manager.currentState
        XCTAssertEqual(afterToggle, beforeToggle)
        XCTAssertEqual(components.rtcManager.encodingConfigurations, encodingBeforeToggle)
        XCTAssertEqual(events.filter { $0["event"] as? String == "start" }.count, 1)
        XCTAssertFalse(events.contains { $0["event"] as? String == "stop" })

        await components.manager.disconnect()
        let clearedTarget = await components.connectionManager.currentTargetSize
        XCTAssertNil(clearedTarget)
        let nextRemote = try await components.manager.connect(localStream: local)
        XCTAssertEqual(nextRemote.videoTrack?.videoFormat, imageFormat)
        let nextTarget = await components.connectionManager.currentTargetSize
        XCTAssertEqual(nextTarget, imageFormat.size)
        await components.manager.close()
    }

    func testUnsupportedDeviceKeepsOriginalReturnSize() async throws {
        let components = makeComponents(frameInterpolationEnabled: true)
        let local = try await components.manager.createLocalImageStream(
            fileURL: URL(fileURLWithPath: "/tmp/reference.png")
        )
        let remote = try await components.manager.connect(localStream: local)
        XCTAssertEqual(remote.videoTrack?.videoFormat, imageFormat)
        let target = await components.connectionManager.currentTargetSize
        XCTAssertEqual(target, imageFormat.size)
        await components.manager.close()
    }

    func testInterpolationDoesNotResizeStreamAlreadyWithinBudget() async throws {
        let components = makeComponents(
            frameInterpolationEnabled: true,
            frameInterpolationSupported: true
        )
        let local = try await components.manager.createLocalCameraStream(videoFormat: videoFormat)
        let remote = try await components.manager.connect(localStream: local)
        XCTAssertEqual(remote.videoTrack?.videoFormat, videoFormat)
        let target = await components.connectionManager.currentTargetSize
        XCTAssertNil(target)
        await components.manager.close()
    }

    func testDisconnectAllowsImmediateReconnectWhileGenerationIsCancelling() async throws {
        for _ in 0..<100 {
            let components = makeComponents()
            let localStream = try await components.manager.createLocalCameraStream(
                videoFormat: videoFormat,
                position: .front
            )
            let starting = Task.detached(priority: .background) {
                try await components.manager.startGeneration(
                    localStream: localStream,
                    context: RealtimeContext(prompt: "video")
                )
            }
            await waitForEvent("start", rtcManager: components.rtcManager)
            await components.manager.disconnect()

            // 不等待旧 startGeneration 的调用方收尾，立即重新连接。
            do {
                _ = try await components.manager.connect(localStream: localStream)
            } catch {
                XCTFail("Immediate reconnect failed: \(error)")
            }
            do {
                _ = try await starting.value
                XCTFail("Expected previous generation to be cancelled")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
            }
            let state = await components.manager.currentState
            XCTAssertEqual(state.connectionState, .connected)
            await components.manager.close()
        }
    }

    func testCameraUsesModelDefaultFrameRate() async throws {
        let components = makeComponents(model: .x2_1)
        let manager: any XmaxRealtimeManaging = components.manager
        let stream = try await manager.createLocalCameraStream()
        let currentTrack = await components.mediaController.currentTrack
        XCTAssertTrue(currentTrack === stream.videoTrack)
        XCTAssertEqual(stream.videoTrack?.videoFormat?.fps, RealtimeModel.x2_1.defaultFrameRate)
        await manager.close()
    }

    func testExternalAudioPublishesOnlyWhileConnectedAndReconnectsWithoutMicrophone() async throws {
        let components = makeComponents()
        let source = RealtimeExternalVideoSourceStub(hasAudio: true)
        let stream = try await components.manager.createExternalVideoStream(source: source)
        let sink = try XCTUnwrap(source.sink)
        let hasAudio = await components.mediaController.hasAudio
        XCTAssertTrue(hasAudio)

        sink.pushAudio(try AudioSampleBufferFactory.make())
        _ = try await components.manager.connect(localStream: stream)
        XCTAssertTrue(components.rtcManager.calls.contains(.publishLocalAudio))
        sink.pushAudio(try AudioSampleBufferFactory.make(timestamp: CMTime(value: 1, timescale: 1)))
        await components.manager.disconnect()
        sink.pushAudio(try AudioSampleBufferFactory.make(timestamp: CMTime(value: 2, timescale: 1)))
        XCTAssertTrue(sink.isRequestingFrames)
        XCTAssertEqual(source.stopCount, 0)

        _ = try await components.manager.connect(localStream: stream)
        sink.pushAudio(try AudioSampleBufferFactory.make(timestamp: CMTime(value: 3, timescale: 1)))
        let sentFrames = components.rtcManager.calls.compactMap { call -> AudioFrame? in
            if case let .pushExternalAudioFrame(frame) = call { return frame }
            return nil
        }
        XCTAssertEqual(sentFrames.map(\.timestampUs), [1000000, 3000000])
        XCTAssertFalse(components.rtcManager.calls.contains(.startAudioCapture))
        await components.manager.close()
        sink.pushAudio(try AudioSampleBufferFactory.make(timestamp: CMTime(value: 4, timescale: 1)))
        XCTAssertFalse(sink.isRequestingFrames)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(components.rtcManager.calls.filter { $0 == .stopExternalAudioSource }.count, 1)
    }

    func testExternalStreamDisconnectPreservesSourceAndCloseUnbinds() async throws {
        let components = makeComponents()
        let source = RealtimeExternalVideoSourceStub()
        let stream = try await components.manager.createExternalVideoStream(source: source)
        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .ready)
        XCTAssertEqual(stream.videoTrack?.videoFormat?.fps, 24)
        let sink = try XCTUnwrap(source.sink)
        _ = try await components.manager.connect(localStream: stream)
        await components.manager.disconnect()
        XCTAssertEqual(source.stopCount, 0)
        XCTAssertTrue(sink.isRequestingFrames)
        XCTAssertFalse(components.rtcManager.calls.contains(.startAudioCapture))
        XCTAssertFalse(components.rtcManager.calls.contains(.startExternalAudioSource))
        await components.manager.close()
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(sink.isRequestingFrames)
    }

    func testExternalStreamStopReturnsToIdleAndRuntimeFailureReleasesSource() async throws {
        let components = makeComponents()
        let source = RealtimeExternalVideoSourceStub()
        _ = try await components.manager.createExternalVideoStream(source: source)
        try await components.manager.stopExternalVideoStream()
        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .idle)
        XCTAssertEqual(source.stopCount, 1)

        let stream = try await components.manager.createExternalVideoStream(source: source)
        _ = try await components.manager.connect(localStream: stream)
        let sink = try XCTUnwrap(source.sink)
        sink.reportError(XmaxError(code: .mediaError, message: "capture failed"))
        for _ in 0..<1000 {
            if source.stopCount == 2 { break }
            try await Task.sleep(nanoseconds: 1000000)
        }
        XCTAssertEqual(source.stopCount, 2)
        XCTAssertFalse(sink.isRequestingFrames)
        await components.manager.close()
    }

    func testCloseCancelsExternalBindingAndInvalidatesSink() async throws {
        let components = makeComponents()
        let source = RealtimeExternalVideoSourceStub()
        source.startHandler = { try await Task.sleep(nanoseconds: 60000000000) }
        let creating = Task { try await components.manager.createExternalVideoStream(source: source) }
        for _ in 0..<1000 {
            if source.sink != nil { break }
            try await Task.sleep(nanoseconds: 1000000)
        }
        let sink = try XCTUnwrap(source.sink)
        await components.manager.close()
        do {
            _ = try await creating.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertFalse(sink.isRequestingFrames)
        XCTAssertEqual(source.stopCount, 1)
        let track = await components.mediaController.currentTrack
        XCTAssertNil(track)
    }

    func testNewMediaStreamsResetRemoteVolumeBySource() async throws {
        let components = makeComponents()
        for source: RealtimeMediaSource in [.camera, .image, .video, .camera] {
            try await components.manager.setRemoteAudioVolume(0.35)
            switch source {
            case .camera:
                _ = try await components.manager.createLocalCameraStream()
            case .image:
                _ = try await components.manager.createLocalImageStream(
                    fileURL: URL(fileURLWithPath: "/tmp/reference.png")
                )
            case .video:
                _ = try await components.manager.createLocalVideoStream(
                    fileURL: URL(fileURLWithPath: "/tmp/source.mp4")
                )
            case .external:
                XCTFail("External input is tested separately")
            }
            let volume = await components.manager.remoteAudioVolume
            XCTAssertEqual(volume, source == .video ? 1 : 0)

            switch source {
            case .camera: try await components.manager.stopLocalCameraStream()
            case .image: try await components.manager.stopLocalImageStream()
            case .video: try await components.manager.stopLocalVideoStream()
            case .external: try await components.manager.stopExternalVideoStream()
            }
        }
        await components.manager.close()
    }

    func testStoppingEachMediaSourceReturnsToIdleAndCanBeRepeated() async throws {
        for source in RealtimeMediaSource.allCases {
            let components = makeComponents()
            switch source {
            case .camera:
                _ = try await components.manager.createLocalCameraStream()
            case .image:
                _ = try await components.manager.createLocalImageStream(imageData: Data([1]))
            case .video:
                _ = try await components.manager.createLocalVideoStream(fileURL: URL(fileURLWithPath: "/tmp/source.mp4"))
            case .external:
                _ = try await components.manager.createExternalVideoStream(source: RealtimeExternalVideoSourceStub())
            }

            for _ in 0..<2 {
                try await stopMediaStream(source, using: components.manager)
                let state = await components.manager.currentState
                let track = await components.mediaController.currentTrack
                XCTAssertEqual(state, RealtimeState(connectionState: .idle), "Source: \(source)")
                XCTAssertNil(track, "Source: \(source)")
            }
            XCTAssertEqual(components.rtcManager.calls.filter { $0 == .destroy }.count, 1)
            await components.manager.close()
        }
    }

    func testStoppingOtherMediaSourcesPreservesTheActiveImagePreview() async throws {
        let components = makeComponents()
        let local = try await components.manager.createLocalImageStream(imageData: Data([1]))
        let track = try XCTUnwrap(local.videoTrack)

        for source in RealtimeMediaSource.allCases where source != .image {
            try await stopMediaStream(source, using: components.manager)
            let state = await components.manager.currentState
            let currentTrack = await components.mediaController.currentTrack
            XCTAssertEqual(state, RealtimeState(connectionState: .ready))
            XCTAssertTrue(currentTrack === track)
            XCTAssertFalse(components.rtcManager.calls.contains(.destroy))
        }
        await components.manager.close()
    }

    func testStoppingAnyMediaSourceWhileConnectedPreservesTheSessionAndPreview() async throws {
        let components = makeComponents()
        let local = try await components.manager.createLocalImageStream(imageData: Data([1]))
        _ = try await components.manager.connect(localStream: local)
        let expectedMessages: [(RealtimeMediaSource, String)] = [
            (.camera, "Disconnect realtime before stopping the local camera stream"),
            (.image, "Disconnect realtime before stopping the local image stream"),
            (.video, "Disconnect realtime before stopping the local video stream"),
            (.external, "Disconnect realtime before stopping the external video stream")
        ]

        for (source, message) in expectedMessages {
            do {
                try await stopMediaStream(source, using: components.manager)
                XCTFail("Expected stopping \(source) while connected to fail")
            } catch {
                XCTAssertEqual(error as? XmaxError, XmaxError(code: .invalidConfiguration, message: message))
            }
            let state = await components.manager.currentState
            let ownsStream = await components.mediaController.owns(local)
            XCTAssertEqual(state.connectionState, .connected)
            XCTAssertEqual(state.sessionID, "session-id")
            XCTAssertTrue(ownsStream)
            XCTAssertFalse(components.rtcManager.calls.contains(.destroy))
        }
        await components.manager.close()
    }

    func testFailedMediaCreationPreservesRemoteVolume() async throws {
        let components = makeComponents(captureManager: CameraCaptureManagingStub(
            startError: XmaxError(code: .mediaError, message: "Capture failed")
        ))
        try await components.manager.setRemoteAudioVolume(0.35)
        do {
            _ = try await components.manager.createLocalCameraStream()
            XCTFail("Expected camera creation to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        let volume = await components.manager.remoteAudioVolume
        XCTAssertEqual(volume, 0.35)
        await components.manager.close()
    }

    func testPublicAudioVolumeControlsForwardNormalizedValues() async throws {
        let components = makeComponents()

        let initialLocalVolume = await components.manager.localAudioVolume
        let initialRemoteVolume = await components.manager.remoteAudioVolume
        XCTAssertEqual(initialLocalVolume, 0.45)
        XCTAssertEqual(initialRemoteVolume, 1)

        try await components.manager.setLocalAudioVolume(0.6)
        try await components.manager.setRemoteAudioVolume(0.35)

        let localVolume = await components.manager.localAudioVolume
        let remoteVolume = await components.manager.remoteAudioVolume
        XCTAssertEqual(localVolume, 0.6)
        XCTAssertEqual(remoteVolume, 0.35)

        XCTAssertTrue(components.videoSource.calls.contains(
            .setLocalAudioVolume(0.6)
        ))

        let localStream = try await components.manager.createLocalVideoStream(
            fileURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )
        let createdVolume = await components.manager.remoteAudioVolume
        XCTAssertEqual(createdVolume, 1)
        try await components.manager.setRemoteAudioVolume(0.35)
        _ = try await components.manager.connect(localStream: localStream)
        let startTask = Task {
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "video")
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let startEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }
        )
        let taskID = try XCTUnwrap(startEvent["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        XCTAssertFalse(components.rtcManager.calls.contains(
            .subscribeRemoteAudio(
                userID: "bot-user",
                subscribe: true
            )
        ))
        try components.rtcManager.emitRemoteVideoFrame()
        try await startTask.value

        XCTAssertTrue(components.rtcManager.calls.contains(
            .setRemoteAudioVolume(35, userID: "bot-user")
        ))

        await components.manager.disconnect()
        let disconnectedVolume = await components.manager.remoteAudioVolume
        XCTAssertEqual(disconnectedVolume, 0.35)
        _ = try await components.manager.connect(localStream: localStream)
        let reconnectedVolume = await components.manager.remoteAudioVolume
        XCTAssertEqual(reconnectedVolume, 0.35)
        await components.manager.disconnect()
        try await components.manager.stopLocalVideoStream()
    }

    func testPublicAudioVolumeControlsRejectOutOfRangeValues() async {
        let components = makeComponents()

        for volume: Float in [-0.01, 1.01, .infinity, .nan] {
            do {
                try await components.manager.setLocalAudioVolume(volume)
                XCTFail("Expected invalid audio volume to fail")
            } catch {
                XCTAssertEqual(
                    error as? XmaxError,
                    XmaxError(
                        code: .invalidConfiguration,
                        message: "Audio volume must be between 0 and 1"
                    )
                )
            }
        }
    }

    func testPublicInterfaceForwardsCameraLifecycle() async throws {
        let components = makeComponents()
        let manager: any XmaxRealtimeManaging = components.manager

        let stream = try await manager.createLocalCameraStream(
            videoFormat: videoFormat
        )
        let switchedStream = try await manager.switchCamera()
        try await manager.stopLocalCameraStream()

        XCTAssertEqual(manager.options.model, .x2_1)
        XCTAssertTrue(stream.videoTrack === switchedStream.videoTrack)
        XCTAssertEqual(switchedStream.videoTrack?.position, .back)
        XCTAssertEqual(components.rtcManager.calls.first, .initialize)
        XCTAssertEqual(components.rtcManager.calls.last, .destroy)
    }

    func testUnsupportedInitialFrameInterpolationDoesNotReportFatalError()
        async throws {
        let components = makeComponents(
            frameInterpolationEnabled: true,
            frameInterpolationSupported: false
        )
        var receivedErrors: [XmaxError] = []
        await components.manager.setStateListener { state in
            if case .failure(let error) = state.reason { receivedErrors.append(error) }
        }

        let stream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat
        )
        let interpolationEnabled =
            await components.manager.isFrameInterpolationEnabled

        XCTAssertNotNil(stream.videoTrack)
        XCTAssertFalse(interpolationEnabled)
        XCTAssertTrue(receivedErrors.isEmpty)
        try await components.manager.stopLocalCameraStream()
    }

    func testPublicInterfaceForwardsImageLifecycle() async throws {
        let components = makeComponents()
        let manager: any XmaxRealtimeManaging = components.manager
        let fileURL = URL(fileURLWithPath: "/tmp/reference.png")

        let stream = try await manager.createLocalImageStream(
            fileURL: fileURL
        )
        try await manager.stopLocalImageStream()

        XCTAssertEqual(stream.videoTrack?.videoFormat, imageFormat)
        XCTAssertNil(stream.videoTrack?.position)
        XCTAssertEqual(components.rtcManager.calls.first, .initialize)
        XCTAssertEqual(components.rtcManager.calls.last, .destroy)
    }

    func testPublicInterfaceAcceptsEncodedImageData() async throws {
        let components = makeComponents()
        let imageData = Data("encoded-image".utf8)

        let stream = try await components.manager.createLocalImageStream(
            imageData: imageData
        )

        XCTAssertEqual(stream.videoTrack?.videoFormat, imageFormat)
        XCTAssertEqual(
            components.imageController.calls,
            [.createData(imageData)]
        )
        try await components.manager.stopLocalImageStream()
    }

    func testPublicInterfaceAcceptsUIKitImage() async throws {
        let components = makeComponents()
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2)
        ).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(
                CGRect(x: 0, y: 0, width: 2, height: 2)
            )
        }

        let stream = try await components.manager.createLocalImageStream(
            image: image
        )

        XCTAssertEqual(stream.videoTrack?.videoFormat, imageFormat)
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(
            components.imageController.calls,
            [
                .createDecoded(
                    CGSize(width: cgImage.width, height: cgImage.height)
                )
            ]
        )
        try await components.manager.stopLocalImageStream()
    }

    func testConnectAndDisconnectPreserveLocalCameraPreview() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )

        let remoteStream = try await components.manager.connect(
            localStream: localStream
        )
        let connectedState = await components.manager.currentState

        XCTAssertEqual(remoteStream.id, StreamID.remote.rawValue)
        XCTAssertEqual(connectedState.connectionState, .connected)
        XCTAssertEqual(connectedState.sessionID, "session-id")
        XCTAssertTrue(
            components.rtcManager.calls.contains(
                .configureVideoEncoding(
                    VideoEncodingConfiguration(
                        width: videoFormat.width,
                        height: videoFormat.height,
                        frameRate: videoFormat.fps,
                        minimumBitrate: 500,
                        maximumBitrate: 1572
                    )
                )
            )
        )

        await components.manager.disconnect()
        let disconnectedState = await components.manager.currentState
        let stillOwnsLocalStream = await components.mediaController.owns(
            localStream
        )

        XCTAssertEqual(disconnectedState.connectionState, .ready)
        XCTAssertEqual(disconnectedState.sessionID, "session-id")
        XCTAssertTrue(stillOwnsLocalStream)
        XCTAssertFalse(components.rtcManager.calls.contains(.destroy))

        try await components.manager.stopLocalCameraStream()
        XCTAssertEqual(components.rtcManager.calls.last, .destroy)
    }

    func testCloseDisconnectsAndReleasesLocalMediaAndRTC() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)

        await components.manager.close()

        let state = await components.manager.currentState
        let stillOwnsLocalStream = await components.mediaController.owns(
            localStream
        )
        XCTAssertEqual(state.connectionState, .idle)
        XCTAssertFalse(stillOwnsLocalStream)
        XCTAssertEqual(
            components.sessionService.calls.filter {
                $0 == .closeSession("session-id")
            }.count,
            1
        )
        XCTAssertEqual(
            components.rtcManager.calls.filter { $0 == .destroy }.count,
            1
        )
    }

    func testDisconnectCancelsOneClickGenerationDuringPreparation() async throws {
        try await assertDisconnectCancelsGenerationDuringPreparation(connectFirst: false)
    }

    func testDisconnectCancelsConnectedGenerationDuringPreparation() async throws {
        try await assertDisconnectCancelsGenerationDuringPreparation(connectFirst: true)
    }

    func testRepeatedCloseReusesSingleReleaseOperation() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)

        async let firstClose: Void = components.manager.close()
        async let secondClose: Void = components.manager.close()
        _ = await (firstClose, secondClose)

        XCTAssertEqual(
            components.sessionService.calls.filter {
                $0 == .closeSession("session-id")
            }.count,
            1
        )
        XCTAssertEqual(
            components.rtcManager.calls.filter { $0 == .destroy }.count,
            1
        )
    }

    func testCloseCancelsMediaWaitingForAnotherManagersEngineLease() async throws {
        let lifecycle = RtcEngineLifecycleRecorder()
        let engineManager = RtcEngineManager(
            appID: "test-app-id",
            makeEngine: lifecycle.create,
            destroyEngine: lifecycle.destroy
        )
        let firstLease = try await engineManager.acquire()
        let waitingRTC = RtcManager(engineManager: engineManager)
        let initializationStarted = expectation(description: "Media initialization started")
        let rtcStub = RtcManagingStub(
            initializationHandler: {
                initializationStarted.fulfill()
                try await waitingRTC.initialize()
            },
            destroyHandler: { await waitingRTC.destroy() }
        )
        let components = makeComponents(rtcManager: rtcStub)
        let creation = Task {
            try await components.manager.createLocalCameraStream(
                videoFormat: videoFormat,
                position: .front
            )
        }
        await fulfillment(of: [initializationStarted], timeout: 2)

        let closed = expectation(description: "Close finishes while the first lease is held")
        let closing = Task {
            await components.manager.close()
            closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 1)
        XCTAssertEqual(lifecycle.createdAppIDs.count, 1)
        XCTAssertEqual(lifecycle.destroyCount, 0)

        // 失败时也释放占用者，让旧实现中的排队任务退出，避免挂住测试进程。
        await engineManager.release(firstLease)
        await closing.value
        do {
            _ = try await creation.value
            XCTFail("Expected local media creation to be cancelled")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        let state = await components.manager.currentState
        let track = await components.mediaController.currentTrack
        XCTAssertEqual(state.connectionState, .idle)
        XCTAssertNil(track)
        XCTAssertTrue(components.captureManager.calls.isEmpty)

        let nextLease = try await engineManager.acquire()
        await engineManager.release(nextLease)
        XCTAssertEqual(lifecycle.createdAppIDs.count, 2)
        XCTAssertEqual(lifecycle.destroyCount, 2)
    }

    func testConnectedIdleCameraSwitchKeepsConnection() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        try await components.manager.setRemoteAudioVolume(0.35)
        _ = try await components.manager.connect(localStream: localStream)

        let switchedStream = try await components.manager.switchCamera()

        XCTAssertEqual(switchedStream.videoTrack?.position, .back)
        let switchedVolume = await components.manager.remoteAudioVolume
        XCTAssertEqual(switchedVolume, 0.35)
        XCTAssertEqual(
            components.rtcManager.calls.filter {
                if case .joinRoom = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertFalse(components.rtcManager.calls.contains(.leaveRoom))
        XCTAssertTrue(decodedEvents(components.rtcManager).isEmpty)

        await components.manager.disconnect()
        try await components.manager.stopLocalCameraStream()
    }

    func testCameraSwitchIsRejectedWhileGenerationIsStarting() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)
        let startTask = Task {
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "prompt")
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)

        do {
            _ = try await components.manager.switchCamera()
            XCTFail("Expected camera switching to be rejected")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while " +
                        "realtime generation is starting"
                )
            )
        }
        XCTAssertFalse(components.captureManager.calls.contains(
            .switchCamera(.back)
        ))

        let taskID = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }?["uid"] as? String
        )
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try components.rtcManager.emitRemoteVideoFrame()
        try await startTask.value

        await components.manager.disconnect()
        try await components.manager.stopLocalCameraStream()
    }

    func testGeneratingCameraSwitchRestartsWithoutReconnect() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front,
            useMicrophone: true
        )
        _ = try await components.manager.connect(localStream: localStream)
        let firstStartTask = Task {
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "prompt"),
                faceRestoration: true
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let firstTaskID = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }?["uid"] as? String
        )
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try components.rtcManager.emitRemoteVideoFrame()
        try await firstStartTask.value

        let switchTask = Task {
            try await components.manager.switchCamera()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            decodedEvents(components.rtcManager).filter {
                $0["event"] as? String == "start"
            }.count,
            1
        )
        await waitForEventCount(
            "start",
            count: 2,
            rtcManager: components.rtcManager
        )
        let startEvents = decodedEvents(components.rtcManager).filter {
            $0["event"] as? String == "start"
        }
        let restartedTaskID = try XCTUnwrap(
            startEvents.last?["uid"] as? String
        )
        XCTAssertNotEqual(restartedTaskID, firstTaskID)
        XCTAssertEqual(
            startEvents.compactMap { ($0["params"] as? [String: Any])?["face_replace"] as? Bool },
            [true, true]
        )
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try components.rtcManager.emitRemoteVideoFrame()

        let switchedStream = try await switchTask.value
        let state = await components.manager.currentState
        XCTAssertEqual(switchedStream.videoTrack?.position, .back)
        XCTAssertEqual(state.connectionState, .generating)
        XCTAssertEqual(state.taskID, restartedTaskID)
        XCTAssertEqual(
            decodedEvents(components.rtcManager).filter {
                $0["event"] as? String == "stop"
            }.count,
            1
        )
        XCTAssertEqual(
            components.sessionService.calls.filter {
                $0 == .createSession(.x2_1)
            }.count,
            1
        )
        XCTAssertEqual(
            components.rtcManager.calls.filter {
                if case .joinRoom = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertFalse(components.rtcManager.calls.contains(.leaveRoom))

        XCTAssertEqual(
            components.rtcManager.calls.filter { $0 == .startAudioCapture }.count,
            1
        )
        XCTAssertFalse(components.rtcManager.calls.contains(.stopAudioCapture))

        await components.manager.disconnect()
        try await components.manager.stopLocalCameraStream()
    }

    func testBothGenerationOverloadsReplaceStartupWithoutReconnecting() async throws {
        for firstIncludesLocalStream in [false, true] {
            let components = makeComponents()
            let localStream = try await components.manager.createLocalImageStream(
                fileURL: URL(fileURLWithPath: "/tmp/image.png")
            )
            _ = try await components.manager.connect(localStream: localStream)

            let first = Task {
                let context = RealtimeContext(prompt: "first")
                if firstIncludesLocalStream {
                    _ = try await components.manager.startGeneration(
                        localStream: localStream,
                        context: context
                    )
                } else {
                    try await components.manager.startGeneration(context: context)
                }
            }
            await waitForEvent("start", rtcManager: components.rtcManager)
            let firstEvent = try XCTUnwrap(decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            })

            let replacement = Task {
                let context = RealtimeContext(prompt: "latest")
                if firstIncludesLocalStream {
                    try await components.manager.startGeneration(context: context)
                } else {
                    _ = try await components.manager.startGeneration(
                        localStream: localStream,
                        context: context
                    )
                }
            }
            await waitForEventCount("start", count: 2, rtcManager: components.rtcManager)
            let latestEvent = try XCTUnwrap(decodedEvents(components.rtcManager).last {
                $0["event"] as? String == "start"
            })
            let latestTaskID = try XCTUnwrap(latestEvent["uid"] as? String)
            XCTAssertNotEqual(firstEvent["uid"] as? String, latestTaskID)

            components.rtcManager.emitRemoteVideoAvailable(
                stream: RemoteStream(roomID: "room-id", userID: "bot-user")
            )
            try components.rtcManager.emitRemoteVideoFrame()
            try await replacement.value
            do {
                try await first.value
                XCTFail("Expected replaced startup cancellation")
            } catch {
                XCTAssertEqual(XmaxError.from(error).code, .cancelled)
            }

            let state = await components.manager.currentState
            XCTAssertEqual(state.connectionState, .generating)
            XCTAssertEqual(state.sessionID, "session-id")
            XCTAssertEqual(state.taskID, latestTaskID)
            XCTAssertEqual(components.sessionService.calls.filter {
                if case .createSession = $0 { return true }
                return false
            }.count, 1)
            XCTAssertFalse(components.sessionService.calls.contains(.closeSession("session-id")))
            XCTAssertFalse(components.rtcManager.calls.contains(.leaveRoom))
            await components.manager.close()
        }
    }

    func testGenerationLifecycleTransitionsAndUpdatesCondition() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)

        let startTask = Task {
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "first")
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let startEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }
        )
        let taskID = try XCTUnwrap(startEvent["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try components.rtcManager.emitRemoteVideoFrame()
        try await startTask.value

        let generatingState = await components.manager.currentState
        XCTAssertEqual(generatingState.connectionState, .generating)
        XCTAssertEqual(generatingState.taskID, taskID)

        try await components.manager.startGeneration(
            context: RealtimeContext(prompt: "second")
        )
        let changeEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).last {
                $0["event"] as? String == "change_condition"
            }
        )
        XCTAssertEqual(changeEvent["uid"] as? String, taskID)
        XCTAssertNil(changeEvent["condition_version"])

        await components.manager.disconnect()
        let stoppedState = await components.manager.currentState
        XCTAssertEqual(stoppedState.connectionState, .ready)
        XCTAssertNil(stoppedState.taskID)

        try await components.manager.stopLocalCameraStream()
    }

    func testVideoGenerationKeepsTimelineRunningAndControlsAudio() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalVideoStream(
            fileURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )
        _ = try await components.manager.connect(localStream: localStream)

        let startTask = Task {
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "video")
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let startEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }
        )
        let taskID = try XCTUnwrap(startEvent["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try components.rtcManager.emitRemoteVideoFrame()
        try await startTask.value

        XCTAssertTrue(components.videoSource.calls.contains(
            .setLocalAudioPreviewMuted(true)
        ))
        XCTAssertFalse(components.videoSource.calls.contains(
            .setLocalAudioPreviewMuted(false)
        ))
        XCTAssertTrue(components.rtcManager.calls.contains(.publishLocalAudio))
        XCTAssertTrue(components.rtcManager.calls.contains(
            .subscribeRemoteAudio(
                userID: "bot-user",
                subscribe: true
            )
        ))

        await components.manager.disconnect()
        XCTAssertTrue(components.videoSource.calls.contains(
            .setLocalAudioPreviewMuted(false)
        ))
        XCTAssertTrue(components.rtcManager.calls.contains(
            .subscribeRemoteAudio(
                userID: "bot-user",
                subscribe: false
            )
        ))
        try await components.manager.stopLocalVideoStream()
    }

    func testGenerationEntryConnectsOnlyAfterUserStartsGeneration()
        async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalVideoStream(
            fileURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )

        XCTAssertFalse(
            components.sessionService.calls.contains(.createSession(.x2_1))
        )

        let startTask = Task {
            try await components.manager.startGeneration(
                localStream: localStream,
                context: RealtimeContext(prompt: "video")
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let startEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }
        )
        let taskID = try XCTUnwrap(startEvent["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try components.rtcManager.emitRemoteVideoFrame()

        let remoteStream = try await startTask.value

        XCTAssertEqual(remoteStream.id, StreamID.remote.rawValue)
        XCTAssertTrue(
            components.sessionService.calls.contains(.createSession(.x2_1))
        )

        await components.manager.disconnect()
        try await components.manager.stopLocalVideoStream()
    }

    func testGenerationEntryRestoresLocalAudioWhenConnectionFails()
        async throws {
        let components = makeComponents(
            sessionCreateError: XmaxError(
                code: .sessionError,
                message: "connect failed"
            )
        )
        let localStream = try await components.manager.createLocalVideoStream(
            fileURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )
        do {
            _ = try await components.manager.startGeneration(
                localStream: localStream,
                context: RealtimeContext(prompt: "video")
            )
            XCTFail("Expected connection to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .sessionError)
        }

        XCTAssertTrue(components.videoSource.calls.contains(
            .setLocalAudioPreviewMuted(true)
        ))
        XCTAssertTrue(components.videoSource.calls.contains(
            .setLocalAudioPreviewMuted(false)
        ))

        try await components.manager.stopLocalVideoStream()
    }

    func testCameraMicrophoneFollowsConnectionLifecycle() async throws {
        let components = makeComponents()
        let manager: any XmaxRealtimeManaging = components.manager
        let stream = try await manager.createLocalCameraStream(useMicrophone: true)
        let hasAudio = await components.mediaController.hasAudio
        XCTAssertTrue(hasAudio)
        XCTAssertFalse(components.rtcManager.calls.contains(.startAudioCapture))
        XCTAssertTrue(components.sessionService.calls.isEmpty)

        _ = try await manager.connect(localStream: stream)
        let calls = components.rtcManager.calls
        let captureIndex = try XCTUnwrap(calls.firstIndex(of: .startAudioCapture))
        let publishIndex = try XCTUnwrap(calls.firstIndex(of: .publishLocalAudio))
        XCTAssertLessThan(captureIndex, publishIndex)

        await manager.disconnect()
        let ownsPreview = await components.mediaController.owns(stream)
        XCTAssertTrue(ownsPreview)
        XCTAssertFalse(components.captureManager.calls.contains(.stop))
        XCTAssertFalse(components.rtcManager.calls.contains(.destroy))

        _ = try await manager.connect(localStream: stream)
        await manager.close()
        XCTAssertEqual(
            components.rtcManager.calls.filter {
                $0 == .startAudioCapture || $0 == .stopAudioCapture
            },
            [.startAudioCapture, .stopAudioCapture, .startAudioCapture, .stopAudioCapture]
        )
        XCTAssertEqual(components.rtcManager.calls.last, .destroy)
    }

    func testCameraWithoutMicrophoneDoesNotCaptureOrPublishAudio() async throws {
        let permissions = PermissionManagingStub()
        let components = makeComponents(permissionManager: permissions)
        let manager: any XmaxRealtimeManaging = components.manager
        let stream = try await manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await manager.connect(localStream: stream)
        await manager.close()

        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        XCTAssertFalse(components.rtcManager.calls.contains(.startAudioCapture))
        XCTAssertFalse(components.rtcManager.calls.contains(.stopAudioCapture))
        XCTAssertFalse(components.rtcManager.calls.contains(.publishLocalAudio))
    }

    func testCameraMicrophonePermissionFailureReleasesRTC() async {
        let expectedError = XmaxError(
            code: .microphonePermissionDenied,
            message: "Microphone access denied"
        )
        let components = makeComponents(
            permissionManager: PermissionManagingStub(microphoneError: expectedError)
        )
        do {
            _ = try await components.manager.createLocalCameraStream(useMicrophone: true)
            XCTFail("Expected microphone permission to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        let track = await components.mediaController.currentTrack
        XCTAssertNil(track)
        XCTAssertFalse(components.rtcManager.calls.contains(.startAudioCapture))
        XCTAssertEqual(components.rtcManager.calls.last, .destroy)
        XCTAssertTrue(components.sessionService.calls.isEmpty)
    }

    func testCameraMicrophoneStartFailureStopsCaptureBeforeCreatingSession() async throws {
        let expectedError = XmaxError(code: .rtcError, message: "Microphone start failed")
        let components = makeComponents(
            rtcManager: RtcManagingStub(startAudioCaptureError: expectedError)
        )
        let stream = try await components.manager.createLocalCameraStream(useMicrophone: true)
        do {
            _ = try await components.manager.connect(localStream: stream)
            XCTFail("Expected microphone start to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        XCTAssertTrue(components.rtcManager.calls.contains(.stopAudioCapture))
        XCTAssertFalse(components.rtcManager.calls.contains(.publishLocalAudio))
        XCTAssertFalse(components.sessionService.calls.contains(.createSession(.x2_1)))
        let ownsPreview = await components.mediaController.owns(stream)
        XCTAssertTrue(ownsPreview)
        await components.manager.close()
    }

    func testCameraConnectionFailureStopsMicrophoneAndPreservesPreview() async throws {
        let expectedError = XmaxError(code: .sessionError, message: "Session creation failed")
        let components = makeComponents(sessionCreateError: expectedError)
        let stream = try await components.manager.createLocalCameraStream(useMicrophone: true)
        do {
            _ = try await components.manager.connect(localStream: stream)
            XCTFail("Expected session creation to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        XCTAssertEqual(
            components.rtcManager.calls.filter {
                $0 == .startAudioCapture || $0 == .stopAudioCapture
            },
            [.startAudioCapture, .stopAudioCapture]
        )
        let ownsPreview = await components.mediaController.owns(stream)
        XCTAssertTrue(ownsPreview)
        await components.manager.close()
    }

    func testCancellingCameraConnectionStopsMicrophone() async throws {
        for closesManager in [false, true] {
            let joining = expectation(description: "RTC join started")
            let rtcManager = RtcManagingStub(joinRoomHandler: { _ in
                joining.fulfill()
                try await Task.sleep(nanoseconds: 30000000000)
            })
            let components = makeComponents(rtcManager: rtcManager)
            let stream = try await components.manager.createLocalCameraStream(useMicrophone: true)
            let connecting = Task {
                try await components.manager.connect(localStream: stream)
            }
            await fulfillment(of: [joining], timeout: 2)
            if closesManager {
                await components.manager.close()
            } else {
                await components.manager.disconnect()
            }
            do {
                _ = try await connecting.value
                XCTFail("Expected connection cancellation")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
            }
            XCTAssertEqual(
                rtcManager.calls.filter { $0 == .startAudioCapture || $0 == .stopAudioCapture },
                [.startAudioCapture, .stopAudioCapture]
            )
            let ownsPreview = await components.mediaController.owns(stream)
            XCTAssertEqual(ownsPreview, !closesManager)
            await components.manager.close()
        }
    }

    func testMicrophoneStopFailureDoesNotPreventCloseFromReleasingRTC() async throws {
        let components = makeComponents(
            rtcManager: RtcManagingStub(stopAudioCaptureError: XmaxError(
                code: .rtcError, message: "Microphone stop failed"
            ))
        )
        let stream = try await components.manager.createLocalCameraStream(useMicrophone: true)
        _ = try await components.manager.connect(localStream: stream)
        await components.manager.close()

        XCTAssertTrue(components.rtcManager.calls.contains(.stopAudioCapture))
        XCTAssertTrue(components.rtcManager.calls.contains(.leaveRoom))
        XCTAssertEqual(components.rtcManager.calls.last, .destroy)
        let track = await components.mediaController.currentTrack
        XCTAssertNil(track)
    }

    func testCameraConnectionUsesExplicitEncodingOptionsAfterSizeResolution() async throws {
        let components = makeComponents()
        let local = try await components.manager.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(
                width: 832, height: 1472, fps: 24,
                minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
            ),
            position: .front
        )
        let expectedFormat = RealtimeVideoFormat(
            width: 1024, height: 768, fps: 24,
            minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
        )
        XCTAssertEqual(local.videoTrack?.videoFormat, expectedFormat)
        _ = try await components.manager.connect(localStream: local)
        XCTAssertEqual(
            components.rtcManager.encodingConfigurations.last,
            VideoEncodingConfiguration(
                width: 1024, height: 768, frameRate: 24,
                minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
            )
        )
        await components.manager.close()
    }

    func testFileVideoPreviewDoesNotConfigureUplinkEncoder() async throws {
        let components = makeComponents()

        _ = try await components.manager.createLocalVideoStream(
            fileURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )

        let configurations = components.rtcManager.calls.compactMap {
            call -> VideoEncodingConfiguration? in
            guard case .configureVideoEncoding(let configuration) = call else {
                return nil
            }
            return configuration
        }
        XCTAssertTrue(configurations.isEmpty)

        try await components.manager.stopLocalVideoStream()
    }

    func testFileVideoEncoderFailureDuringConnectPreservesLocalStream() async throws {
        let expectedError = XmaxError(
            code: .rtcError,
            message: "Failed to configure video encoding"
        )
        let components = makeComponents(
            rtcManager: RtcManagingStub(encodingError: expectedError)
        )

        let local = try await components.manager.createLocalVideoStream(
            fileURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )
        do {
            _ = try await components.manager.connect(localStream: local)
            XCTFail("Expected video encoding configuration to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }

        let currentTrack = await components.mediaController.currentTrack
        XCTAssertTrue(currentTrack === local.videoTrack)
        XCTAssertTrue(components.videoSource.calls.contains(.start))
        XCTAssertFalse(components.videoSource.calls.contains(.stop))
        await components.manager.close()
    }

    func testRepeatedDisconnectReusesSingleTermination() async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)

        async let firstDisconnect: Void = components.manager.disconnect()
        async let secondDisconnect: Void = components.manager.disconnect()
        _ = await (firstDisconnect, secondDisconnect)

        XCTAssertEqual(
            components.sessionService.calls.filter {
                $0 == .closeSession("session-id")
            }.count,
            1
        )
        XCTAssertEqual(
            components.rtcManager.calls.filter { $0 == .leaveRoom }.count,
            1
        )
        try await components.manager.stopLocalCameraStream()
    }

    func testHeartbeatFailureReportsErrorAndTerminatesConnection() async throws {
        let components = makeComponents()
        var receivedErrors: [XmaxError] = []
        await components.manager.setStateListener { state in
            if case .failure(let error) = state.reason { receivedErrors.append(error) }
        }
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)
        let expectedError = XmaxError(
            code: .sessionError,
            message: "session closed"
        )

        await components.sessionService.failHeartbeat(
            sessionID: "session-id",
            error: XmaxError(
                code: .sessionError,
                message: "session closed"
            )
        )

        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .ready)
        XCTAssertEqual(receivedErrors, [expectedError])
        XCTAssertFalse(components.rtcManager.calls.contains(.destroy))
        try await components.manager.stopLocalCameraStream()
    }

    func testDisconnectGenerationFailureDoesNotReportFatalError() async throws {
        let components = makeComponents()
        var receivedErrors: [XmaxError] = []
        await components.manager.setStateListener { state in
            if case .failure(let error) = state.reason { receivedErrors.append(error) }
        }
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)
        let startTask = Task {
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "prompt")
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        let startEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }
        )
        let taskID = try XCTUnwrap(startEvent["uid"] as? String)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: RemoteStream(
                roomID: "room-id",
                userID: "bot-user"
            ))
        try components.rtcManager.emitRemoteVideoFrame()
        try await startTask.value
        let signalingError = XmaxError(
            code: .rtcError,
            message: "sendRoomMessage failed: -1"
        )
        components.rtcManager.setSendRoomMessageError(signalingError)

        await components.manager.disconnect()

        XCTAssertTrue(receivedErrors.isEmpty)
        try await components.manager.stopLocalCameraStream()
    }

    func testDisconnectSessionCleanupFailureDoesNotReportError() async throws {
        let expectedError = XmaxError(
            code: .networkError,
            message: "close session failed"
        )
        let components = makeComponents(sessionCloseError: expectedError)
        var receivedErrors: [XmaxError] = []
        await components.manager.setStateListener { state in
            if case .failure(let error) = state.reason { receivedErrors.append(error) }
        }
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        _ = try await components.manager.connect(localStream: localStream)

        await components.manager.disconnect()

        XCTAssertTrue(receivedErrors.isEmpty)
        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .ready)
        XCTAssertEqual(state.sessionID, "session-id")
        try await components.manager.stopLocalCameraStream()
    }

    func testStateListenerReceivesCurrentAndLifecycleStates() async throws {
        let components = makeComponents()
        var states: [RealtimeConnectionState] = []
        await components.manager.setStateListener { state in
            states.append(state.connectionState)
        }
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )

        _ = try await components.manager.connect(localStream: localStream)
        await components.manager.disconnect()

        XCTAssertEqual(
            states,
            [.idle, .preparing, .connecting, .connected, .disconnecting, .ready]
        )
        try await components.manager.stopLocalCameraStream()
    }

    func testCameraFormatUpdateRequiresReadyPreviewAndPreservesEncodingOptions() async throws {
        let components = makeComponents(cameraMediaService: MediaService(model: .x2_1))
        let manager: any XmaxRealtimeManaging = components.manager
        let initial = RealtimeVideoFormat(
            width: 1080, height: 1920, fps: 24,
            minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainFramerate
        )
        let updated = initial.resized(width: 1920, height: 1080)
        let ready = expectation(description: "Camera is ready")
        await manager.setStateListener { state in
            if state.connectionState == .ready { ready.fulfill() }
        }
        let stream = try await manager.createLocalCameraStream(videoFormat: initial)
        do {
            try await manager.updateCameraFormat(updated)
            XCTFail("Expected update during preparation to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        let track = try XCTUnwrap(stream.videoTrack)
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
        let view = XmaxRealtimeVideoView()
        try binding.attach(to: view, contentMode: .fit)
        try components.captureManager.emitFrame(CameraControllerTests.testFrame())
        await fulfillment(of: [ready], timeout: 2)
        await manager.setStateListener(nil)

        try await manager.updateCameraFormat(updated)
        let current = await manager.currentCameraVideoFormat
        let preset = await manager.currentCameraPreset
        XCTAssertEqual(current, updated)
        XCTAssertEqual(preset, .resolution1920x1080)
        XCTAssertEqual(track.videoFormat, current)
        XCTAssertEqual(view.bounds, .zero)

        try await manager.connect(localStream: stream)
        do {
            try await manager.updateCameraFormat(initial)
            XCTFail("Expected update while connected to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertEqual(track.videoFormat, current)
        await manager.close()
    }

    func testCameraPresetCreationUsesAllSupportedModelFormats() async throws {
        for preset in RealtimeCameraPreset.allCases {
            let components = makeComponents(cameraMediaService: MediaService(model: .x2_1))
            let manager: any XmaxRealtimeManaging = components.manager
            let stream = try await manager.createLocalCameraStream(preset: preset)
            XCTAssertEqual(stream.videoTrack?.videoFormat?.size, preset.size)
            XCTAssertEqual(stream.videoTrack?.videoFormat?.fps, RealtimeModel.x2_1.defaultFrameRate)
            let currentPreset = await manager.currentCameraPreset
            XCTAssertEqual(currentPreset, preset)
            await manager.close()
        }
    }

    func testCameraReadyRequiresCapturedFrameAndAttachedPreview() async throws {
        for frameArrivesFirst in [false, true] {
            let components = makeComponents()
            var states: [RealtimeConnectionState] = []
            let ready = expectation(description: "Camera preview becomes ready")
            await components.manager.setStateListener { state in
                states.append(state.connectionState)
                if state.connectionState == .ready { ready.fulfill() }
            }
            let stream = try await components.manager.createLocalCameraStream()
            let initialState = await components.manager.currentState
            XCTAssertEqual(initialState.connectionState, .preparing)
            let track = try XCTUnwrap(stream.videoTrack)
            let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
            let view = XmaxRealtimeVideoView()
            let frame = try CameraControllerTests.testFrame()

            if frameArrivesFirst {
                try components.captureManager.emitFrame(frame)
            } else {
                try binding.attach(to: view, contentMode: .fill)
            }
            let partialState = await components.manager.currentState
            XCTAssertEqual(partialState.connectionState, .preparing)

            if frameArrivesFirst {
                try binding.attach(to: view, contentMode: .fill)
            } else {
                try components.captureManager.emitFrame(frame)
            }
            await fulfillment(of: [ready], timeout: 2)
            XCTAssertEqual(states, [.idle, .preparing, .ready])
            try components.captureManager.emitFrame(frame)
            let currentState = await components.manager.currentState
            XCTAssertEqual(currentState.connectionState, .ready)
            XCTAssertEqual(states, [.idle, .preparing, .ready])
            await components.manager.close()
        }
    }

    func testConnectRejectsStreamOwnedByAnotherManager() async throws {
        let components = makeComponents()
        var receivedError: XmaxError?
        await components.manager.setStateListener { state in
            if case .failure(let error) = state.reason { receivedError = error }
        }
        let foreignTrack = RealtimeVideoTrack(
            id: "foreign",
            videoFormat: videoFormat
        )

        do {
            _ = try await components.manager.connect(
                localStream: RealtimeMediaStream(
                    id: StreamID.local.rawValue,
                    videoTrack: foreignTrack
                )
            )
            XCTFail("Expected foreign stream to be rejected")
        } catch {
            XCTAssertEqual(
                (error as? XmaxError)?.code,
                .invalidConfiguration
            )
        }
        XCTAssertNil(receivedError)
    }

    func testQualityListenersReceiveRtcEvents() async {
        let components = makeComponents()
        var receivedQuality: RealtimeNetworkQuality?
        var receivedAlarm: RealtimePerformanceAlarm?
        await components.manager.setNetworkQualityListener { quality in
            receivedQuality = quality
        }
        await components.manager.setPerformanceAlarmListener { alarm in
            receivedAlarm = alarm
        }

        components.rtcManager.emitNetworkQuality(
            uplink: .good,
            downlink: .poor
        )
        components.rtcManager.emitPerformanceAlarm(
            limited: true,
            suggestedWidth: 540,
            suggestedHeight: 960,
            suggestedFrameRate: 15
        )

        XCTAssertEqual(
            receivedQuality,
            RealtimeNetworkQuality(uplink: .good, downlink: .poor)
        )
        XCTAssertEqual(receivedAlarm?.status, .limited)
        XCTAssertEqual(receivedAlarm?.suggestedVideoFormat?.fps, 15)
    }
}

private extension XmaxRealtimeManagerTests {
    func stopMediaStream(
        _ source: RealtimeMediaSource,
        using manager: any XmaxRealtimeManaging
    ) async throws {
        switch source {
        case .camera:
            try await manager.stopLocalCameraStream()
        case .image:
            try await manager.stopLocalImageStream()
        case .video:
            try await manager.stopLocalVideoStream()
        case .external:
            try await manager.stopExternalVideoStream()
        }
    }

    func assertGenerationPadding(
        components: Components,
        localStream: RealtimeMediaStream,
        canvasSize: CGSize,
        contain: Bool
    ) async throws {
        do {
            let mediaFormat = try XCTUnwrap(localStream.videoTrack?.videoFormat)
            let start = Task {
                try await components.manager.startGeneration(
                    localStream: localStream,
                    context: RealtimeContext(prompt: "initial")
                )
            }
            await waitForEvent("start", rtcManager: components.rtcManager)
            let remoteStream = RemoteStream(roomID: "room-id", userID: "bot-user")
            components.rtcManager.emitRemoteVideoAvailable(stream: remoteStream)
            for _ in 0..<1000 {
                if components.rtcManager.calls.contains(.setRemoteVideoFrameListener(remoteStream, enabled: true)) {
                    break
                }
                try await Task.sleep(nanoseconds: 1000000)
            }
            try components.rtcManager.emitRemoteVideoFrame()
            _ = try await start.value
            try await components.manager.startGeneration(
                context: RealtimeContext(prompt: "updated")
            )

            let events = decodedEvents(components.rtcManager).filter {
                ["start", "change_condition"].contains($0["event"] as? String ?? "")
            }
            XCTAssertEqual(events.count, 2)
            for event in events {
                let parameters = try XCTUnwrap(event["params"] as? [String: Any])
                XCTAssertEqual(parameters["size"] as? [Int], [Int(canvasSize.width), Int(canvasSize.height)])
                XCTAssertEqual(parameters["padding"] as? String, contain ? "contain" : nil)
            }
            let startEvent = try XCTUnwrap(events.first)
            let startParameters = try XCTUnwrap(startEvent["params"] as? [String: Any])
            XCTAssertEqual(startParameters["target_size"] as? [Int], [mediaFormat.width, mediaFormat.height])
            XCTAssertEqual(localStream.videoTrack?.videoFormat, mediaFormat)
        } catch {
            await components.manager.close()
            throw error
        }
        await components.manager.close()
    }

    struct Components {
        let manager: XmaxRealtimeManager
        let connectionManager: XmaxRealtimeConnectionManager
        let mediaController: MediaController
        let rtcManager: RtcManagingStub
        let captureManager: CameraCaptureManagingStub
        let sessionService: RealtimeSessionServicingStub
        let imageController: ImageControllingStub
        let videoSource: VideoPlayerControllingStub
    }

    var videoFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(width: 1_024, height: 768, fps: 24)
    }

    var imageFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(width: 832, height: 1_472, fps: 24)
    }

    func makeComponents(
        rtcManager: RtcManagingStub = RtcManagingStub(),
        captureManager: CameraCaptureManagingStub = CameraCaptureManagingStub(),
        permissionManager: PermissionManagingStub = PermissionManagingStub(),
        cameraMediaService: (any MediaServicing)? = nil,
        model: RealtimeModel = .x2_1,
        imageVideoFormat: RealtimeVideoFormat? = nil,
        sessionCreateError: (any Error)? = nil,
        sessionCloseError: (any Error)? = nil,
        frameInterpolationEnabled: Bool = false,
        frameInterpolationSupported: Bool = false,
        initialQualityLevel: RealtimeQualityLevel = .l1,
        isAdaptiveQualityEnabled: Bool = true
    ) -> Components {
        let errorManager = XmaxRealtimeErrorManager()
        let mediaService = MediaServicingStub(
            resolvedSize: CGSize(width: 1_024, height: 768),
            frameInterpolationSupported: frameInterpolationSupported
        )
        let renderController = RenderController(
            rtcManager: rtcManager,
            frameInterpolationEnabled: frameInterpolationEnabled,
            frameInterpolationSupportChecker: { mediaService.supportsFrameInterpolation(for: $0) },
            errorListener: { errorManager.forward($0, target: .connection) }
        )
        let suite = "xmax-manager-test-" + UUID().uuidString
        qualityHistorySuites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let history = QualityHistory(model: model.rawValue, defaults: defaults)
        history.write(level: initialQualityLevel, downlink: false)
        history.write(level: initialQualityLevel, downlink: true)
        let streamController = StreamController(
            rtcManager: rtcManager,
            roomController: RoomController(rtcManager: rtcManager),
            encodingController: EncodingController(rtcManager: rtcManager),
            qualityController: QualityController(rtcManager: rtcManager, historyDefaults: defaults),
            errorListener: { errorManager.forward($0, target: .connection) },
            remoteStreamListener: { stream in
                try renderController.setRemoteStream(stream)
            },
            generationTiming: StreamGenerationTiming(
                timeoutNanoseconds: 1_000_000_000
            )
        )
        let cameraController = CameraController(
            rtcManager: rtcManager,
            permissionManager: permissionManager,
            mediaService: cameraMediaService ?? mediaService,
            captureManager: captureManager,
            videoFrameListener: { try streamController.pushLocalVideoFrame($0) },
            errorListener: { errorManager.forward($0, target: .all) }
        )
        let imageController = ImageControllingStub(
            resolvedFormat: imageVideoFormat ?? imageFormat
        )
        let videoSource = VideoPlayerControllingStub()
        let videoController = VideoController(
            rtcManager: rtcManager,
            metadataManager: MediaFileMetadataManagingStub(),
            mediaService: mediaService,
            playerController: videoSource
        )
        let mediaController = MediaController(
            rtcManager: rtcManager,
            cameraController: cameraController,
            imageController: imageController,
            interactionListener: { taskID, points in
                try await streamController.sendTracks(taskID: taskID, points: points)
            },
            videoController: videoController,
            externalController: ExternalVideoController(
                rtcManager: rtcManager,
                mediaService: MediaService(model: model),
                videoFrameListener: { try streamController.pushLocalVideoFrame($0) },
                audioFrameListener: { try streamController.pushLocalAudioFrame($0) },
                errorListener: { errorManager.forward($0, target: .all) }
            )
        )
        let sessionService = RealtimeSessionServicingStub(
            session: RealtimeSession(
                id: "session-id",
                userID: "user-id",
                status: "ACTIVE",
                connection: RealtimeSessionConnection(
                    roomID: "room-id",
                    userID: "user-id",
                    token: "room-token",
                    botName: "bot-user"
                ),
                closeReason: nil
            ),
            createError: sessionCreateError,
            closeError: sessionCloseError
        )
        let connectionManager = XmaxRealtimeConnectionManager(
            errorManager: errorManager,
            interactionController: mediaController,
            renderController: renderController,
            streamController: streamController,
            sessionService: sessionService,
            mediaService: mediaService
        )
        return Components(
            manager: XmaxRealtimeManager(
                options: RealtimeConfiguration(
                    model: model,
                    isFrameInterpolationEnabled:
                        frameInterpolationEnabled,
                    isAdaptiveQualityEnabled: isAdaptiveQualityEnabled
                ),
                streamController: streamController,
                mediaController: mediaController,
                renderController: renderController,
                mediaService: mediaService,
                connectionManager: connectionManager,
                errorManager: errorManager,
                generationManager: XmaxRealtimeGenerationManager(
                    interactionController: mediaController,
                    streamController: streamController,
                    renderController: renderController
                )
            ),
            connectionManager: connectionManager,
            mediaController: mediaController,
            rtcManager: rtcManager,
            captureManager: captureManager,
            sessionService: sessionService,
            imageController: imageController,
            videoSource: videoSource
        )
    }

    func assertDisconnectCancelsGenerationDuringPreparation(
        connectFirst: Bool
    ) async throws {
        let components = makeComponents()
        let localStream = try await components.manager.createLocalCameraStream(
            videoFormat: videoFormat,
            position: .front
        )
        if connectFirst {
            _ = try await components.manager.connect(localStream: localStream)
        }

        // 卡住连接状态查询，确保断开发生在生成准备阶段，而非进房之后。
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let queryBlocked = expectation(description: "Connection queries blocked")
        let holding = Task.detached {
            await components.connectionManager.holdQueries(
                gate: gate,
                entered: { queryBlocked.fulfill() }
            )
        }
        await fulfillment(of: [queryBlocked], timeout: 2)

        let startEntered = expectation(description: "Generation call entered")
        let starting = Task {
            try await components.manager.startGenerationDuringPreparationTest(
                localStream: connectFirst ? nil : localStream,
                entered: { startEntered.fulfill() }
            )
        }
        await fulfillment(of: [startEntered], timeout: 2)

        let disconnecting = expectation(description: "Pending generation cancelled")
        await components.manager.setStateListener { state in
            if state.connectionState == .disconnecting {
                disconnecting.fulfill()
            }
        }
        let closing = Task { await components.manager.disconnect() }
        await fulfillment(of: [disconnecting], timeout: 2)
        gate.signal()
        let gateReleased = await holding.value
        XCTAssertTrue(gateReleased)
        await closing.value

        do {
            try await starting.value
            XCTFail("Expected generation preparation to be cancelled")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        let state = await components.manager.currentState
        let ownsLocalStream = await components.mediaController.owns(localStream)
        XCTAssertEqual(state.connectionState, .ready)
        XCTAssertTrue(ownsLocalStream)
        XCTAssertFalse(decodedEvents(components.rtcManager).contains {
            $0["event"] as? String == "start"
        })
        if !connectFirst {
            XCTAssertFalse(components.sessionService.calls.contains {
                if case .createSession = $0 { return true }
                return false
            })
        }
        await components.manager.setStateListener(nil)
        await components.manager.close()
    }

    func makeBGRAFrame(timestampUs: Int64) throws -> VideoFrame {
        try VideoFrame(
            format: VideoFormat(
                width: 1,
                height: 1,
                pixelFormat: .bgra
            ),
            timestampUs: timestampUs,
            planes: [
                VideoFramePlane(
                    data: Data([0, 0, 0, 255]),
                    stride: 4
                )
            ]
        )
    }

    func waitForEvent(
        _ event: String,
        rtcManager: RtcManagingStub
    ) async {
        for _ in 0..<1_000 {
            if decodedEvents(rtcManager).contains(where: {
                $0["event"] as? String == event
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for room event: \(event)")
    }

    func waitForEventCount(
        _ event: String,
        count: Int,
        rtcManager: RtcManagingStub
    ) async {
        for _ in 0..<1_000 {
            let matchingEvents = decodedEvents(rtcManager).filter {
                $0["event"] as? String == event
            }
            if matchingEvents.count >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail(
            "Timed out waiting for room event: \(event), count: \(count)"
        )
    }

    func decodedEvents(
        _ rtcManager: RtcManagingStub
    ) -> [[String: Any]] {
        rtcManager.managerMessages.compactMap { message in
            guard let data = message.data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock {
            storedValue += 1
        }
    }
}

private extension RtcManagingStub {
    var managerMessages: [String] {
        calls.compactMap { call in
            guard case .sendRoomMessage(let message) = call else {
                return nil
            }
            return message
        }
    }
}
