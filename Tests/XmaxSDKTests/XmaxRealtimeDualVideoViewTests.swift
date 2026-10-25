//
//  XmaxRealtimeDualVideoViewTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AVFoundation
import UIKit
import XCTest
@testable import XmaxSDK

/// Tests the layered local and remote video view.
@MainActor
final class XmaxRealtimeDualVideoViewTests: XCTestCase {
    func testRemoteFadeInDurationDefaultsToPointThreeSeconds() {
        XCTAssertEqual(XmaxRealtimeDualVideoView().remoteVideoFadeInDuration, 0.3)
        XCTAssertEqual(XmaxRealtimeDualVideoView(frame: .zero).remoteVideoFadeInDuration, 0.3)
        XCTAssertEqual(
            XmaxRealtimeDualVideo(localTrack: nil, remoteTrack: nil).remoteVideoFadeInDuration,
            0.3
        )
    }

    func testRemoteVideoWithoutAnimationStillWaitsForFirstFrame() throws {
        let remoteTrack = RealtimeVideoTrack(id: "remote")
        VideoRenderRegistry.register(
            remoteTrack,
            binding: VideoRenderBinding(
                attachHandler: { _, _ in },
                detachHandler: { _ in }
            )
        )
        defer { VideoRenderRegistry.unregister(remoteTrack) }
        let view = XmaxRealtimeDualVideoView(
            remoteTrack: remoteTrack,
            remoteVideoFadeInDuration: 0
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)
        let remoteVideoView = try XCTUnwrap(
            view.subviews.compactMap { $0 as? XmaxRealtimeVideoView }.last
        )
        XCTAssertTrue(remoteVideoView.isHidden)

        let animationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(animationsEnabled) }
        try remoteVideoView.displayImageFrame(makeImageFrame(), contentMode: .fit)

        XCTAssertFalse(remoteVideoView.isHidden)
        XCTAssertEqual(remoteVideoView.alpha, 1)
        XCTAssertTrue(remoteVideoView.layer.animationKeys()?.isEmpty ?? true)
    }

    func testConfiguredRemoteFadeInDurationIsApplied() throws {
        let remoteTrack = RealtimeVideoTrack(id: "remote")
        VideoRenderRegistry.register(
            remoteTrack,
            binding: VideoRenderBinding(
                attachHandler: { _, _ in },
                detachHandler: { _ in }
            )
        )
        defer { VideoRenderRegistry.unregister(remoteTrack) }
        let view = XmaxRealtimeDualVideoView(
            remoteTrack: remoteTrack,
            remoteVideoFadeInDuration: 0.8
        )
        let controller = UIViewController()
        controller.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let remoteVideoView = try XCTUnwrap(
            view.subviews.compactMap { $0 as? XmaxRealtimeVideoView }.last
        )
        view.remoteVideoFadeInDuration = 0.6

        let animationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(animationsEnabled) }
        try remoteVideoView.displayImageFrame(makeImageFrame(), contentMode: .fit)
        CATransaction.flush()

        let animation = try XCTUnwrap(remoteVideoView.layer.animation(forKey: "opacity"))
        XCTAssertEqual(animation.duration, 0.6, accuracy: 0.001)
        XCTAssertFalse(remoteVideoView.isHidden)
    }

    func testContentModeChangeUpdatesBothPreviewLayersWithoutReplacingTracks() throws {
        let localTrack = RealtimeVideoTrack(id: "local")
        let remoteTrack = RealtimeVideoTrack(id: "remote")
        let localPresenter = DecodedVideoPreviewPresenter()
        let remotePresenter = DecodedVideoPreviewPresenter()

        for (track, presenter) in [(localTrack, localPresenter), (remoteTrack, remotePresenter)] {
            VideoRenderRegistry.register(track, binding: VideoRenderBinding(
                attachHandler: { view, contentMode in
                    presenter.attach(to: try XCTUnwrap(view as? XmaxRealtimeVideoView), contentMode: contentMode)
                },
                detachHandler: { view in
                    presenter.detach(from: try XCTUnwrap(view as? XmaxRealtimeVideoView))
                }
            ))
        }
        defer {
            VideoRenderRegistry.unregister(localTrack)
            VideoRenderRegistry.unregister(remoteTrack)
        }

        let view = XmaxRealtimeDualVideoView(localTrack: localTrack, remoteTrack: remoteTrack)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 300))
        view.frame = window.bounds
        window.addSubview(view)
        view.layoutIfNeeded()

        let videoViews = view.subviews.compactMap { $0 as? XmaxRealtimeVideoView }
        XCTAssertEqual(videoViews.count, 2)
        for mode in [VideoContentMode.fit, .fill, .fit] {
            view.videoContentMode = mode

            for videoView in videoViews {
                let layer = try XCTUnwrap(videoView.layer.sublayers?.compactMap {
                    $0 as? AVSampleBufferDisplayLayer
                }.first)
                XCTAssertEqual(videoView.videoContentMode, mode)
                XCTAssertEqual(layer.videoGravity, mode == .fit ? .resizeAspect : .resizeAspectFill)
            }
            XCTAssertTrue(videoViews[0].track === localTrack)
            XCTAssertTrue(videoViews[1].track === remoteTrack)
        }
    }

    func testTracksAreBoundToLayeredVideoViews() {
        let localTrack = RealtimeVideoTrack(id: "local")
        let remoteTrack = RealtimeVideoTrack(id: "remote")
        let view = XmaxRealtimeDualVideoView(
            localTrack: localTrack,
            remoteTrack: remoteTrack
        )

        let videoViews = view.subviews.compactMap { $0 as? XmaxRealtimeVideoView }

        XCTAssertEqual(videoViews.count, 2)
        XCTAssertTrue(videoViews[0].track === localTrack)
        XCTAssertTrue(videoViews[1].track === remoteTrack)
        XCTAssertTrue(videoViews[1].isHidden)
    }

    func testRemoteVideoAppearsAfterFirstFrameAndHidesWhenCleared() throws {
        let remoteTrack = RealtimeVideoTrack(id: "remote")
        VideoRenderRegistry.register(
            remoteTrack,
            binding: VideoRenderBinding(imageFrame: try makeImageFrame())
        )
        defer { VideoRenderRegistry.unregister(remoteTrack) }
        let view = XmaxRealtimeDualVideoView(remoteTrack: remoteTrack)
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }

        window.addSubview(view)

        let remoteVideoView = try XCTUnwrap(
            view.subviews.compactMap { $0 as? XmaxRealtimeVideoView }.last
        )
        XCTAssertFalse(remoteVideoView.isHidden)
        XCTAssertEqual(remoteVideoView.alpha, 1)

        view.remoteTrack = nil

        XCTAssertTrue(remoteVideoView.isHidden)
        XCTAssertEqual(remoteVideoView.alpha, 0)
        XCTAssertNil(remoteVideoView.track)
    }

    func testRemoteVideoRemainsHiddenBeforeFirstFrame() {
        let remoteTrack = RealtimeVideoTrack(id: "remote")
        VideoRenderRegistry.register(
            remoteTrack,
            binding: VideoRenderBinding(
                attachHandler: { _, _ in },
                detachHandler: { _ in }
            )
        )
        defer { VideoRenderRegistry.unregister(remoteTrack) }
        let view = XmaxRealtimeDualVideoView(remoteTrack: remoteTrack)
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )

        window.addSubview(view)

        let remoteVideoView = view.subviews
            .compactMap { $0 as? XmaxRealtimeVideoView }
            .last
        XCTAssertTrue(remoteVideoView?.isHidden == true)
    }
}

private extension XmaxRealtimeDualVideoViewTests {
    func makeImageFrame() throws -> VideoFrame {
        try VideoFrame(
            format: VideoFormat(
                width: 1,
                height: 1,
                pixelFormat: .bgra
            ),
            timestampUs: 0,
            planes: [
                VideoFramePlane(
                    data: Data([0, 0, 0, 255]),
                    stride: 4
                )
            ]
        )
    }
}
