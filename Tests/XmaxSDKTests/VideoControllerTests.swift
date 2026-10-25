//
//  VideoControllerTests.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import UIKit
import XCTest
@testable import XmaxSDK

@MainActor
final class VideoControllerTests: XCTestCase {
    func testCreateWithAudioStartsPlayerAndExternalAudioWithoutMicrophone() async throws {
        let components = makeComponents(hasAudio: true)
        let stream = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        XCTAssertEqual(stream.videoTrack?.videoFormat, videoFormat)
        XCTAssertTrue(components.controller.hasAudio)
        XCTAssertEqual(components.player.calls, [configurationCall(hasAudio: true), .start])
        XCTAssertTrue(components.rtc.calls.contains(.useExternalVideoSource))
        XCTAssertTrue(components.rtc.calls.contains(.startExternalAudioSource))
        XCTAssertFalse(components.rtc.calls.contains(.startAudioCapture))
        await components.controller.stopLocalVideoStream()
    }

    func testSilentVideoDoesNotStartExternalAudioOrMutePlayer() async throws {
        let components = makeComponents(hasAudio: false)
        _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        await components.controller.setLocalAudioPreviewMuted(true)
        XCTAssertFalse(components.controller.hasAudio)
        XCTAssertFalse(components.rtc.calls.contains(.startExternalAudioSource))
        XCTAssertFalse(components.rtc.calls.contains(.startAudioCapture))
        XCTAssertFalse(components.player.calls.contains(.setLocalAudioPreviewMuted(true)))
        await components.controller.stopLocalVideoStream()
    }

    func testStopReleasesAudioTrackAndPreviewBinding() async throws {
        let components = makeComponents(hasAudio: true)
        let stream = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        let track = try XCTUnwrap(stream.videoTrack)
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        await components.controller.stopLocalVideoStream()
        XCTAssertEqual(components.player.calls.last, .stop)
        XCTAssertTrue(components.rtc.calls.contains(.stopExternalAudioSource))
        XCTAssertNil(components.controller.currentTrack)
        XCTAssertFalse(components.controller.hasAudio)
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
    }

    func testLargeRotatedVideoConfiguresCappedDisplaySizeAndPreservesDuration() async throws {
        let player = VideoPlayerControllingStub()
        let rtc = RtcManagingStub()
        let controller = VideoController(
            rtcManager: rtc,
            metadataManager: MediaFileMetadataManagingStub(metadata: MediaFileMetadata(
                width: 3840, height: 2160, rotation: .rotation90,
                durationSeconds: 2.0000001, hasAudio: true
            )),
            playerController: player
        )
        let stream = try await controller.createLocalVideoStream(fileURL: fileURL)
        XCTAssertEqual(stream.videoTrack?.videoFormat, videoFormat)
        XCTAssertEqual(player.calls.first, configurationCall(
            hasAudio: true,
            sourceWidth: 3840,
            sourceHeight: 2160
        ))
        await controller.stopLocalVideoStream()
    }

    func testMediaUsesSourceRatioAndModelDefaultFrameRateOutsideCameraBuckets() async throws {
        let player = VideoPlayerControllingStub()
        let service = MediaServicingStub(resolvedSize: .zero)
        let controller = VideoController(
            rtcManager: RtcManagingStub(),
            metadataManager: MediaFileMetadataManagingStub(metadata: MediaFileMetadata(
                width: 1280, height: 720, rotation: .rotation0,
                durationSeconds: 5, hasAudio: false
            )),
            mediaService: service,
            playerController: player
        )
        let stream = try await controller.createLocalVideoStream(fileURL: fileURL)
        XCTAssertEqual(stream.videoTrack?.videoFormat, RealtimeVideoFormat(width: 1280, height: 720, fps: 30))
        XCTAssertEqual(service.requestedSizes, [CGSize(width: 1280, height: 720)])
        XCTAssertEqual(player.calls.first, .configure(
            fileURL: fileURL,
            metadata: MediaFileMetadata(
                width: 1280,
                height: 720,
                rotation: .rotation0,
                durationSeconds: 5,
                hasAudio: false
            ),
            videoFormat: RealtimeVideoFormat(width: 1280, height: 720, fps: 30)
        ))
        await controller.stopLocalVideoStream()
    }

    func testDuplicateCreateIsRejectedAndStoppedControllerCanBeReused() async throws {
        let components = makeComponents(hasAudio: true)
        _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        let calls = components.player.calls
        do {
            _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
            XCTFail("Expected duplicate creation to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertEqual(components.player.calls, calls)
        await components.controller.stopLocalVideoStream()
        _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        XCTAssertEqual(components.player.calls.filter { $0 == .start }.count, 2)
        await components.controller.stopLocalVideoStream()
    }

    func testLocalAudioControlsForwardToPlayerAndVolumeSurvivesCreation() async throws {
        let components = makeComponents(hasAudio: true)
        await components.controller.setLocalAudioVolume(0.7)
        let volume = await components.controller.localAudioVolume
        XCTAssertEqual(volume, 0.7)
        _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        await components.controller.setLocalAudioPreviewMuted(true)
        await components.controller.setLocalAudioPreviewMuted(false)
        XCTAssertEqual(Array(components.player.calls.suffix(2)), [
            .setLocalAudioPreviewMuted(true), .setLocalAudioPreviewMuted(false)
        ])
        XCTAssertEqual(components.player.localAudioVolume, 0.7)
        await components.controller.stopLocalVideoStream()
    }

    func testPlayerStartFailureRollsBackAudioAndAllowsRetry() async throws {
        let components = makeComponents(hasAudio: true)
        components.player.startError = XmaxError(code: .mediaError, message: "start failed")
        do {
            _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
            XCTFail("Expected startup failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertEqual(components.player.calls.last, .stop)
        XCTAssertTrue(components.rtc.calls.contains(.stopExternalAudioSource))
        XCTAssertNil(components.controller.currentTrack)
        XCTAssertFalse(components.controller.hasAudio)
        components.player.startError = nil
        _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        await components.controller.stopLocalVideoStream()
    }

    func testConfigureFailureDoesNotStartRtcAudioAndAllowsRetry() async throws {
        let components = makeComponents(hasAudio: true)
        components.player.configureError = XmaxError(code: .mediaError, message: "configure failed")
        do {
            _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
            XCTFail("Expected configuration failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertTrue(components.rtc.calls.isEmpty)
        XCTAssertEqual(components.player.calls.last, .stop)
        components.player.configureError = nil
        _ = try await components.controller.createLocalVideoStream(fileURL: fileURL)
        await components.controller.stopLocalVideoStream()
    }

    func testCancellationWhileStartingRollsBackExternalAudio() async throws {
        let components = makeComponents(hasAudio: true)
        components.player.startHandler = { try await Task.sleep(nanoseconds: 60000000000) }
        let starting = Task { try await components.controller.createLocalVideoStream(fileURL: fileURL) }
        for _ in 0..<1000 {
            if components.player.calls.contains(.start) { break }
            try await Task.sleep(nanoseconds: 1000000)
        }
        starting.cancel()
        do {
            _ = try await starting.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertTrue(components.rtc.calls.contains(.stopExternalAudioSource))
        XCTAssertEqual(components.player.calls.last, .stop)
        XCTAssertNil(components.controller.currentTrack)
    }

    private var fileURL: URL { URL(fileURLWithPath: "/tmp/source.mp4") }

    private var videoFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(width: 1080, height: 1920, fps: 30)
    }

    private func configurationCall(
        hasAudio: Bool,
        sourceWidth: Int = 1920,
        sourceHeight: Int = 1080
    ) -> VideoPlayerControllingCall {
        .configure(
            fileURL: fileURL,
            metadata: MediaFileMetadata(
                width: sourceWidth,
                height: sourceHeight,
                rotation: .rotation90,
                durationSeconds: 2.0000001,
                hasAudio: hasAudio
            ),
            videoFormat: videoFormat
        )
    }

    private func makeComponents(hasAudio: Bool) -> (controller: VideoController, rtc: RtcManagingStub, player: VideoPlayerControllingStub) {
        let rtc = RtcManagingStub()
        let player = VideoPlayerControllingStub()
        let controller = VideoController(
            rtcManager: rtc,
            metadataManager: MediaFileMetadataManagingStub(metadata: MediaFileMetadata(
                width: 1920, height: 1080, rotation: .rotation90,
                durationSeconds: 2.0000001, hasAudio: hasAudio
            )),
            playerController: player
        )
        return (controller, rtc, player)
    }
}
