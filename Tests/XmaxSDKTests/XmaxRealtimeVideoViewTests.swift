//
//  XmaxRealtimeVideoViewTests.swift
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

/// Tests single-track video rendering and interaction.
@MainActor
final class XmaxRealtimeVideoViewTests: XCTestCase {
    func testRotationObserverNotifiesTargetBeforeTransitionCompletes() {
        let track = RealtimeVideoTrack(id: "local")
        var notifications = 0
        track.orientationChangeHandler = { if $0 { notifications += 1 } }
        let view = XmaxRealtimeVideoView(track: track)
        view.updateInterfaceOrientation(.portrait)
        let observer = VideoOrientationObserver(videoView: view, deviceOrientation: { .landscapeRight })
        let transition = VideoRotationTransitionStub(angle: .pi / 2)

        observer.viewWillTransition(to: CGSize(width: 844, height: 390), with: transition)

        XCTAssertTrue(observer.isTransitioning)
        XCTAssertEqual(track.displayOrientation, .landscapeLeft)
        XCTAssertEqual(notifications, 1)

        transition.finish()
        XCTAssertFalse(observer.isTransitioning)
        XCTAssertEqual(track.displayOrientation, .landscapeLeft)
        XCTAssertEqual(notifications, 1)
    }

    func testRotationObserverIgnoresNonRotationResize() {
        let track = RealtimeVideoTrack(id: "local")
        let view = XmaxRealtimeVideoView(track: track)
        view.updateInterfaceOrientation(.portrait)
        let observer = VideoOrientationObserver(videoView: view)

        observer.viewWillTransition(
            to: CGSize(width: 600, height: 400),
            with: VideoRotationTransitionStub(angle: 0)
        )

        XCTAssertFalse(observer.isTransitioning)
        XCTAssertEqual(track.displayOrientation, .portrait)
    }

    func testDeviceOrientationMapsToInterfaceOrientation() {
        for (device, expected) in [
            (UIDeviceOrientation.portrait, UIInterfaceOrientation.portrait),
            (.portraitUpsideDown, .portraitUpsideDown),
            (.landscapeLeft, .landscapeRight),
            (.landscapeRight, .landscapeLeft)
        ] {
            XCTAssertEqual(
                VideoOrientationObserver.interfaceOrientation(for: device),
                expected
            )
        }
        for device in [UIDeviceOrientation.unknown, .faceUp, .faceDown] {
            XCTAssertNil(VideoOrientationObserver.interfaceOrientation(for: device))
        }
    }

    func testRotationDoesNotRotateAgainWhenLayoutAlreadyAppliedTargetOrientation() {
        let track = RealtimeVideoTrack(id: "local")
        let view = XmaxRealtimeVideoView(track: track)
        view.updateInterfaceOrientation(.landscapeRight)
        let observer = VideoOrientationObserver(videoView: view, deviceOrientation: { .landscapeLeft })
        let transition = VideoRotationTransitionStub(angle: -.pi / 2)

        observer.viewWillTransition(to: CGSize(width: 844, height: 390), with: transition)

        XCTAssertEqual(track.displayOrientation, .landscapeRight)
        transition.finish()
        XCTAssertEqual(track.displayOrientation, .landscapeRight)
    }

    func testRotationObserverIsRemovedWithVideoView() {
        let track = RealtimeVideoTrack(id: "local")
        track.orientationChangeHandler = { _ in }
        let view = XmaxRealtimeVideoView(track: track)
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(parent.view)
        parent.view.addSubview(view)

        XCTAssertEqual(parent.children.filter { $0 is VideoOrientationObserver }.count, 1)
        view.removeFromSuperview()
        XCTAssertTrue(parent.children.isEmpty)
    }

    func testOrientationChangesOnlyNotifyWhenSwitchingBetweenPortraitAndLandscape() {
        let track = RealtimeVideoTrack(id: "local")
        var notifications = 0
        track.orientationChangeHandler = { if $0 { notifications += 1 } }
        let view = XmaxRealtimeVideoView(track: track)

        view.updateInterfaceOrientation(.unknown)
        view.updateInterfaceOrientation(.portrait)
        view.updateInterfaceOrientation(.portraitUpsideDown)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(track.displayOrientation, .portraitUpsideDown)

        view.updateInterfaceOrientation(.landscapeLeft)
        view.updateInterfaceOrientation(.landscapeRight)
        view.updateInterfaceOrientation(.unknown)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(track.displayOrientation, .landscapeRight)

        view.updateInterfaceOrientation(.portrait)
        XCTAssertEqual(notifications, 2)
    }

    func testNewTrackStartsWithItsOwnOrientationBaseline() {
        let first = RealtimeVideoTrack(id: "first")
        let second = RealtimeVideoTrack(id: "second")
        var notifications = 0
        first.orientationChangeHandler = { if $0 { notifications += 1 } }
        second.orientationChangeHandler = { if $0 { notifications += 1 } }
        let view = XmaxRealtimeVideoView(track: first)
        view.updateInterfaceOrientation(.portrait)

        view.track = second
        view.updateInterfaceOrientation(.landscapeLeft)
        XCTAssertEqual(notifications, 0)

        view.updateInterfaceOrientation(.portrait)
        XCTAssertEqual(notifications, 1)
    }

    func testInitializationUsesPublicRenderingDefaults() {
        let track = RealtimeVideoTrack(id: "track")

        let view = XmaxRealtimeVideoView(track: track)

        XCTAssertTrue(view.track === track)
        XCTAssertEqual(view.videoContentMode, .fill)
        XCTAssertTrue(view.isInteractionEnabled)
        XCTAssertEqual(view.backgroundColor, .black)
        XCTAssertTrue(view.clipsToBounds)
    }

    func testInitializationAcceptsInteractionState() {
        let view = XmaxRealtimeVideoView(isInteractionEnabled: false)

        XCTAssertFalse(view.isInteractionEnabled)
    }

    func testMovingIntoWindowBindsTrackWithContentMode() {
        let recorder = VideoBindingRecorder()
        let track = RealtimeVideoTrack(id: "track")
        register(track: track, recorder: recorder)
        defer { VideoRenderRegistry.unregister(track) }
        let view = XmaxRealtimeVideoView(
            track: track,
            videoContentMode: .fit
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        window.addSubview(view)

        XCTAssertEqual(recorder.events, [.attach("track", .fit)])
    }

    func testChangingContentModeRefreshesRenderBinding() {
        let recorder = VideoBindingRecorder()
        let track = RealtimeVideoTrack(id: "track")
        register(track: track, recorder: recorder)
        defer { VideoRenderRegistry.unregister(track) }
        let view = XmaxRealtimeVideoView(track: track)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)

        view.videoContentMode = .fit

        XCTAssertEqual(
            recorder.events,
            [.attach("track", .fill), .attach("track", .fit)]
        )
    }

    func testChangingTrackDetachesPreviousBindingAndAttachesNextTrack() {
        let recorder = VideoBindingRecorder()
        let firstTrack = RealtimeVideoTrack(id: "first")
        let secondTrack = RealtimeVideoTrack(id: "second")
        register(track: firstTrack, recorder: recorder)
        register(track: secondTrack, recorder: recorder)
        defer {
            VideoRenderRegistry.unregister(firstTrack)
            VideoRenderRegistry.unregister(secondTrack)
        }
        let view = XmaxRealtimeVideoView(track: firstTrack)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)

        view.track = secondTrack

        XCTAssertEqual(
            recorder.events,
            [
                .attach("first", .fill),
                .detach("first"),
                .attach("second", .fill)
            ]
        )
    }

    func testMovingOutOfWindowDetachesCurrentTrack() {
        let recorder = VideoBindingRecorder()
        let track = RealtimeVideoTrack(id: "track")
        register(track: track, recorder: recorder)
        defer { VideoRenderRegistry.unregister(track) }
        let view = XmaxRealtimeVideoView(track: track)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)

        view.removeFromSuperview()

        XCTAssertEqual(
            recorder.events,
            [.attach("track", .fill), .detach("track")]
        )
    }

    func testImageTrackUsesUIImageViewRendering() throws {
        let track = RealtimeVideoTrack(id: "image-track")
        VideoRenderRegistry.register(
            track,
            binding: VideoRenderBinding(
                imageFrame: try VideoFrame(
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
            )
        )
        defer { VideoRenderRegistry.unregister(track) }
        let view = XmaxRealtimeVideoView(track: track)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        window.addSubview(view)

        let imageView = try XCTUnwrap(
            view.subviews.compactMap { $0 as? UIImageView }.first
        )
        XCTAssertFalse(imageView.isHidden)
        XCTAssertNotNil(imageView.image)

        view.track = nil

        XCTAssertTrue(imageView.isHidden)
        XCTAssertNil(imageView.image)
    }

    func testNV12FrameCanBeDisplayedAsStaticPreview() throws {
        let image = try XmaxRealtimeVideoView.makeImage(makeNV12Frame(timestampUs: 0))

        XCTAssertEqual(image.size, CGSize(width: 2, height: 2))
    }

    func testPreviewPoolKeepsInFlightPixelsAndReusesFormatDescription() throws {
        let view = XmaxRealtimeVideoView()
        let frame = try makeNV12Frame(timestampUs: 0)
        let first = try view.makeLocalPreviewPixelBuffer(frame)
        let firstDescription = try view.localPreviewDescription(for: first)
        let second = try view.makeLocalPreviewPixelBuffer(frame)

        XCTAssertFalse(first === second)
        XCTAssertTrue(firstDescription === (try view.localPreviewDescription(for: second)))
        let restored = try VideoFrameConverter.convert(
            pixelBuffer: first, outputWidth: 2, outputHeight: 2,
            rotation: .rotation0, timestampUs: 0
        )
        XCTAssertEqual(restored.planes[0].data, frame.planes[0].data)

        let largerFrame = try VideoFrame(
            format: VideoFormat(width: 4, height: 2, pixelFormat: .nv12),
            timestampUs: 1,
            planes: [
                VideoFramePlane(data: Data(repeating: 64, count: 8), stride: 4),
                VideoFramePlane(data: Data(repeating: 128, count: 4), stride: 4)
            ]
        )
        let larger = try view.makeLocalPreviewPixelBuffer(largerFrame)
        let description = try view.localPreviewDescription(for: larger)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(description).width, 4)
        XCTAssertEqual(CVPixelBufferGetWidth(first), 2)

        view.clearDecodedVideoPreview()
        let restarted = try view.makeLocalPreviewPixelBuffer(frame)
        XCTAssertEqual(CVPixelBufferGetWidth(restarted), 2)
    }

    func testNV12CropOnlyPathPreservesPlaneOffsetsAndPadding() throws {
        let frame = try VideoFrame(
            format: VideoFormat(width: 4, height: 2, pixelFormat: .nv12),
            timestampUs: 123,
            planes: [
                VideoFramePlane(data: Data([10, 20, 30, 40, 50, 60, 70, 80]), stride: 4),
                VideoFramePlane(data: Data([100, 110, 120, 130]), stride: 4)
            ]
        )
        let buffer = try XmaxRealtimeVideoView.makeNV12PixelBuffer(frame)
        let cropped = try VideoFrameConverter.convert(
            pixelBuffer: buffer, outputWidth: 2, outputHeight: 2,
            rotation: .rotation0, timestampUs: 123
        )

        XCTAssertEqual(cropped.planes[0].data, Data([10, 20, 50, 60, 100, 110]))
        XCTAssertEqual(cropped.timestampUs, 123)
    }

    func testExternalBGRAPreviewCopiesPixelsAndReconfiguresPool() throws {
        let view = XmaxRealtimeVideoView()
        let frame = try VideoFrame(
            format: VideoFormat(width: 2, height: 2, pixelFormat: .bgra),
            timestampUs: 0,
            planes: [VideoFramePlane(data: Data(repeating: 42, count: 16), stride: 8)]
        )
        let first = try view.makeLocalPreviewPixelBuffer(frame)
        let description = try view.localPreviewDescription(for: first)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(first), kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(first, .readOnly)
        XCTAssertEqual(CVPixelBufferGetBaseAddress(first)?.load(as: UInt8.self), 42)
        CVPixelBufferUnlockBaseAddress(first, .readOnly)
        let second = try view.makeLocalPreviewPixelBuffer(frame)
        XCTAssertFalse(first === second)
        XCTAssertTrue(description === (try view.localPreviewDescription(for: second)))

        let nv12 = try view.makeLocalPreviewPixelBuffer(makeNV12Frame(timestampUs: 1))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(nv12), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertFalse(description === (try view.localPreviewDescription(for: nv12)))
        let bgra = try view.makeLocalPreviewPixelBuffer(frame)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(bgra), kCVPixelFormatType_32BGRA)
    }

    func testChangingPreviewDimensionsAndGravityKeepsLayerWithoutAnimations() throws {
        let view = XmaxRealtimeVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.prepareDecodedVideoPreview(contentMode: .fill)
        let layer = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        let originalBounds = view.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(false)
        defer { CATransaction.commit() }

        for (width, height, mode) in [(4, 2, VideoContentMode.fill), (2, 2, .fit), (2, 4, .fill)] {
            let frame = try VideoFrame(
                format: VideoFormat(width: width, height: height, pixelFormat: .nv12),
                timestampUs: 0,
                planes: [
                    VideoFramePlane(data: Data(repeating: 128, count: width * height), stride: width),
                    VideoFramePlane(data: Data(repeating: 128, count: width * height / 2), stride: width)
                ]
            )
            view.prepareDecodedVideoPreview(contentMode: mode)
            view.displayDecodedVideoFrame(frame, contentMode: mode)
            view.setNeedsLayout()
            view.layoutIfNeeded()

            XCTAssertTrue(layer === view.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
            XCTAssertEqual(layer.videoGravity, mode == .fit ? .resizeAspect : .resizeAspectFill)
            XCTAssertEqual(layer.frame, originalBounds)
            XCTAssertEqual(view.bounds, originalBounds)
            XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
            XCTAssertFalse(CATransaction.disableActions())
        }
    }

    func testDecodedPreviewMirrorChangesWithoutRecreatingLayer() throws {
        let view = XmaxRealtimeVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let presenter = DecodedVideoPreviewPresenter()
        presenter.setMirrored(true)
        presenter.attach(to: view, contentMode: .fit)
        let layer = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        XCTAssertEqual(layer.affineTransform().a, -1)
        XCTAssertEqual(layer.videoGravity, .resizeAspect)
        for key in ["bounds", "position", "transform", "videoGravity"] {
            XCTAssertTrue(layer.actions?[key] is NSNull)
        }
        presenter.setMirrored(false)
        XCTAssertEqual(layer.affineTransform(), .identity)
        presenter.detach(from: view)
        XCTAssertNil(layer.superlayer)
    }

}

@MainActor
private final class VideoRotationTransitionStub: NSObject, UIViewControllerTransitionCoordinator {
    // 过渡配置
    let targetTransform: CGAffineTransform
    let containerView = UIView()
    let isAnimated = true
    let presentationStyle = UIModalPresentationStyle.none
    let initiallyInteractive = false
    let isInterruptible = false
    let isInteractive = false
    let isCancelled = false
    let transitionDuration: TimeInterval = 0.3
    let percentComplete: CGFloat = 0
    let completionVelocity: CGFloat = 0
    let completionCurve = UIView.AnimationCurve.easeInOut

    // 完成通知
    private var completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?

    init(angle: CGFloat) {
        targetTransform = CGAffineTransform(rotationAngle: angle)
        super.init()
    }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }

    func animate(
        alongsideTransition animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
        completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?
    ) -> Bool {
        animation?(self)
        self.completion = completion
        return true
    }

    func animateAlongsideTransition(
        in view: UIView?,
        animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
        completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?
    ) -> Bool {
        animate(alongsideTransition: animation, completion: completion)
    }

    func notifyWhenInteractionEnds(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}
    func notifyWhenInteractionChanges(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}

    func finish() {
        completion?(self)
        completion = nil
    }
}

private extension XmaxRealtimeVideoViewTests {
    func register(
        track: RealtimeVideoTrack,
        recorder: VideoBindingRecorder
    ) {
        VideoRenderRegistry.register(
            track,
            binding: VideoRenderBinding(
                attachHandler: { _, contentMode in
                    recorder.events.append(.attach(track.id, contentMode))
                },
                detachHandler: { _ in
                    recorder.events.append(.detach(track.id))
                }
            )
        )
    }

    func makeNV12Frame(timestampUs: Int64) throws -> VideoFrame {
        let data = Data([
            64, 96,
            128, 160,
            128, 128,
        ])
        return try VideoFrame(
            format: VideoFormat(
                width: 2,
                height: 2,
                pixelFormat: .nv12
            ),
            timestampUs: timestampUs,
            planes: [
                VideoFramePlane(
                    data: data,
                    stride: 2,
                    byteLength: 4
                ),
                VideoFramePlane(
                    data: data,
                    stride: 2,
                    byteOffset: 4,
                    byteLength: 2
                ),
            ]
        )
    }
}

@MainActor
private final class VideoBindingRecorder {
    enum Event: Equatable {
        case attach(String, VideoContentMode)
        case detach(String)
    }

    // 绑定记录
    var events: [Event] = []
}
