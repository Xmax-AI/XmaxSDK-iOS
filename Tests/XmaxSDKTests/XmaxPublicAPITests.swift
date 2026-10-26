//
//  XmaxPublicAPITests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import CoreMedia
import Foundation
import UIKit
import XCTest
import XmaxSDK

final class XmaxPublicAPITests: XCTestCase {
    func testPublicLoggerOptionsAreComposable() {
        let options: XmaxLoggerOption = [.business, .performance]
        let configuration = XmaxConfiguration(
            apiKey: "test-key",
            loggerOptions: options
        )

        XCTAssertEqual(options, .all)
        XCTAssertEqual(configuration.loggerOptions, .all)
    }

    @MainActor
    func testClientCreatesPublicRealtimeManager() {
        let client = XmaxClient(
            configuration: XmaxConfiguration(apiKey: "test-key")
        )

        let manager: any XmaxRealtimeManaging = client.createRealtimeManager(
            options: RealtimeConfiguration(
                model: .x2_1,
                isFrameInterpolationEnabled: true
            )
        )

        XCTAssertEqual(manager.options.model, .x2_1)
        XCTAssertTrue(manager.options.isFrameInterpolationEnabled)
    }

    @MainActor
    func testPublicRemoteMediaListenerIsAvailable() async throws {
        let manager = XmaxClient(configuration: XmaxConfiguration(apiKey: "test-key"))
            .createRealtimeManager(options: RealtimeConfiguration(model: .x2_1))
        let listener: RealtimeMediaFrameListener = { event in
            _ = event.streamID
            _ = event.isDiscontinuous
            _ = event.presentationTimeStamp
            _ = event.duration
            switch event.content {
            case .audio(let frame):
                _ = frame.data
                _ = frame.sampleRate
                _ = frame.channels
                _ = frame.samplesPerChannel
                _ = frame.presentationTimeStamp
                _ = frame.duration
            case .video(let frame):
                _ = frame.pixelBuffer
                _ = frame.presentationTimeStamp
                _ = frame.duration
            }
        }
        try await manager.setRemoteMediaFrameListener(listener)
        try await manager.setRemoteMediaFrameListener(nil)
    }

    func testPublicRealtimeCameraModelsAreConstructible() throws {
        let format = RealtimeVideoFormat(
            width: 1_024,
            height: 768,
            fps: 30
        )
        let position: CameraPosition = .front

        try format.validate()

        XCTAssertEqual(format.width, 1_024)
        XCTAssertEqual(format.height, 768)
        XCTAssertEqual(format.fps, 30)
        XCTAssertEqual(position.rawValue, "front")
    }

    func testPublicRealtimeContextIsConstructible() {
        let context = RealtimeContext(
            prompt: " prompt ",
            referencePath: " reference/image.png "
        )

        XCTAssertEqual(context.prompt, "prompt")
        XCTAssertEqual(context.referencePath, "reference/image.png")
    }

    @MainActor
    func testPublicRealtimeQualityModelsAreConstructible() {
        let networkQuality = RealtimeNetworkQuality(
            uplink: .excellent,
            downlink: .good
        )
        let performanceAlarm = RealtimePerformanceAlarm(
            status: .limited,
            suggestedVideoFormat: RealtimeVideoFormat(
                width: 540,
                height: 960,
                fps: 15
            )
        )
        let networkListener: RealtimeNetworkQualityListener = { _ in }
        let performanceListener: RealtimePerformanceAlarmListener = { _ in }

        networkListener(networkQuality)
        performanceListener(performanceAlarm)

        XCTAssertEqual(networkQuality.uplink, .excellent)
        XCTAssertEqual(networkQuality.downlink, .good)
        XCTAssertEqual(performanceAlarm.status, .limited)
        XCTAssertEqual(performanceAlarm.suggestedVideoFormat?.fps, 15)
    }

    @MainActor
    func testPublicVideoViewAcceptsRealtimeTrackAndContentMode() {
        let view = XmaxRealtimeVideoView(
            videoContentMode: .fit,
            isInteractionEnabled: false
        )

        view.track = nil
        view.videoContentMode = .fill

        XCTAssertNil(view.track)
        XCTAssertEqual(view.videoContentMode, .fill)
        XCTAssertFalse(view.isInteractionEnabled)
    }

    @MainActor
    func testPublicSwiftUIVideoAcceptsTrackAndDisplayOptions() {
        let video = XmaxRealtimeVideo(
            track: nil,
            videoContentMode: .fit,
            isInteractionEnabled: false
        )

        XCTAssertNil(video.track)
        XCTAssertEqual(video.videoContentMode, .fit)
        XCTAssertFalse(video.isInteractionEnabled)
    }

    @MainActor
    func testPublicDualVideoViewAcceptsLocalAndRemoteTracks() {
        let view = XmaxRealtimeDualVideoView(
            localTrack: nil,
            remoteTrack: nil,
            videoContentMode: .fit,
            remoteVideoFadeInDuration: 0.7,
            isInteractionEnabled: false
        )

        XCTAssertNil(view.localTrack)
        XCTAssertNil(view.remoteTrack)
        XCTAssertEqual(view.videoContentMode, .fit)
        XCTAssertEqual(view.remoteVideoFadeInDuration, 0.7)
        XCTAssertFalse(view.isInteractionEnabled)
        XCTAssertEqual(view.subviews.compactMap { $0 as? XmaxRealtimeVideoView }.count, 2)
    }

    @MainActor
    func testPublicSwiftUIDualVideoAcceptsTracksAndDisplayOptions() {
        let video = XmaxRealtimeDualVideo(
            localTrack: nil,
            remoteTrack: nil,
            videoContentMode: .fit,
            remoteVideoFadeInDuration: 0,
            isInteractionEnabled: false
        )

        XCTAssertNil(video.localTrack)
        XCTAssertNil(video.remoteTrack)
        XCTAssertEqual(video.videoContentMode, .fit)
        XCTAssertEqual(video.remoteVideoFadeInDuration, 0)
        XCTAssertFalse(video.isInteractionEnabled)
    }

    @MainActor
    func testClientCreatesPublicMediaService() {
        let client = XmaxClient(
            configuration: XmaxConfiguration(apiKey: "test-key")
        )

        let service: any MediaServicing = client.createMediaService()

        XCTAssertNotNil(service as Any)
        XCTAssertFalse(
            service.supportsFrameInterpolation(
                for: CGSize(width: 0, height: 1_280)
            )
        )
    }

    private func createDefaultCameraStream(
        using manager: any XmaxRealtimeManaging,
        videoFormat: RealtimeVideoFormat
    ) async throws -> RealtimeMediaStream {
        try await manager.createLocalCameraStream(videoFormat: videoFormat)
    }

    private func stopCameraStream(
        using manager: any XmaxRealtimeManaging
    ) async throws {
        try await manager.stopLocalCameraStream()
    }

    private func createDefaultImageStream(
        using manager: any XmaxRealtimeManaging,
        fileURL: URL
    ) async throws -> RealtimeMediaStream {
        try await manager.createLocalImageStream(fileURL: fileURL)
    }

    private func createImageDataStream(
        using manager: any XmaxRealtimeManaging,
        imageData: Data
    ) async throws -> RealtimeMediaStream {
        try await manager.createLocalImageStream(imageData: imageData)
    }

    @MainActor
    private func createUIKitImageStream(
        using manager: any XmaxRealtimeManaging,
        image: UIImage
    ) async throws -> RealtimeMediaStream {
        try await manager.createLocalImageStream(image: image)
    }

    private func stopImageStream(
        using manager: any XmaxRealtimeManaging
    ) async throws {
        try await manager.stopLocalImageStream()
    }

    private func createDefaultVideoStream(
        using manager: any XmaxRealtimeManaging,
        fileURL: URL
    ) async throws -> RealtimeMediaStream {
        try await manager.createLocalVideoStream(fileURL: fileURL)
    }

    private func stopVideoStream(
        using manager: any XmaxRealtimeManaging
    ) async throws {
        try await manager.stopLocalVideoStream()
    }

    private func startGeneration(
        using manager: any XmaxRealtimeManaging,
        localStream: RealtimeMediaStream,
        context: RealtimeContext?,
        faceRestoration: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await manager.startGeneration(
            localStream: localStream,
            context: context,
            faceRestoration: faceRestoration
        )
    }

    private func readPublicRealtimeStream(
        _ stream: RealtimeMediaStream
    ) -> (String, String?, RealtimeVideoFormat?, CameraPosition?) {
        (
            stream.id,
            stream.videoTrack?.id,
            stream.videoTrack?.videoFormat,
            stream.videoTrack?.position
        )
    }
}
