import UIKit
import XmaxSDK

final class RealtimePreviewBackdropView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    // 显示配置
    private let usesFileLayout: Bool
    private let trajectoryRenderer: (any TrajectoryEffectRendering)?

    private var gradientLayer: CAGradientLayer {
        layer as! CAGradientLayer
    }

    // 媒体视图
    private let videoViewportView = UIView()

    private lazy var realtimeVideoView: XmaxRealtimeDualVideoView = {
        let view = XmaxRealtimeDualVideoView(videoContentMode: .fit)
        view.trajectoryRenderer = trajectoryRenderer
        view.backgroundColor = .feed(rgb: 0x101010)
        return view
    }()

    // 摄像头切换动画
    private lazy var cameraSwitchBlurView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: nil)
        view.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }()

    private var cameraSwitchVersion: UInt64 = 0
    private var isCameraSwitchTransitionActive = false
    private var hasCompletedCameraSwitchFlip = false

    init(
        usesFileLayout: Bool,
        trajectoryRenderer: (any TrajectoryEffectRendering)? = nil
    ) {
        self.usesFileLayout = usesFileLayout
        self.trajectoryRenderer = trajectoryRenderer
        super.init(frame: .zero)
        clipsToBounds = true
        gradientLayer.colors = [
            UIColor.feed(rgb: 0x171719).cgColor,
            UIColor.feed(rgb: 0x0D0D0F).cgColor,
            UIColor.feed(rgb: 0x050506).cgColor
        ]
        gradientLayer.locations = [0, 0.48, 1]
        gradientLayer.startPoint = CGPoint(x: 0.25, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.75, y: 1)

        videoViewportView.clipsToBounds = true
        addSubview(videoViewportView)
        videoViewportView.addSubview(realtimeVideoView)
        videoViewportView.addSubview(cameraSwitchBlurView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoViewportView.frame = bounds
        let contentFrame = videoViewportView.bounds
        realtimeVideoView.frame = contentFrame
        updateVideoContentMode()
        cameraSwitchBlurView.frame = contentFrame
        realtimeVideoView.layoutIfNeeded()
    }

    func updateVideoContentMode() {
        guard !usesFileLayout, let format = realtimeVideoView.localTrack?.videoFormat else {
            realtimeVideoView.videoContentMode = .fit
            return
        }
        let fillsViewport = format.width == 1080 && format.height == 1920
        realtimeVideoView.videoContentMode = fillsViewport ? .fill : .fit
    }

    func displayLocal(_ track: RealtimeVideoTrack?) {
        updateLocal(track)
        realtimeVideoView.remoteTrack = nil
    }

    func updateLocal(_ track: RealtimeVideoTrack?) {
        realtimeVideoView.localTrack = track
        updateVideoContentMode()
    }

    func displayRealtime(_ track: RealtimeVideoTrack?) {
        realtimeVideoView.remoteTrack = track
    }

    func hideRealtime() {
        realtimeVideoView.remoteTrack = nil
    }

    func setCameraSwitchTransitionActive(_ isActive: Bool) {
        guard isCameraSwitchTransitionActive != isActive else { return }
        isCameraSwitchTransitionActive = isActive
        if isActive {
            beginCameraSwitchTransition()
        } else {
            finishCameraSwitchTransitionIfReady()
        }
    }
}

private extension RealtimePreviewBackdropView {
    func beginCameraSwitchTransition() {
        cameraSwitchVersion &+= 1
        let version = cameraSwitchVersion
        hasCompletedCameraSwitchFlip = false
        hideRealtime()

        realtimeVideoView.layer.removeAllAnimations()
        cameraSwitchBlurView.layer.removeAllAnimations()
        cameraSwitchBlurView.isHidden = false
        UIView.performWithoutAnimation {
            realtimeVideoView.layer.transform = CATransform3DIdentity
            cameraSwitchBlurView.layer.transform = CATransform3DIdentity
            cameraSwitchBlurView.alpha = 1
            cameraSwitchBlurView.effect = nil
        }

        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn]
        ) {
            self.cameraSwitchBlurView.effect = UIBlurEffect(
                style: .systemChromeMaterialDark
            )
        } completion: { [weak self] _ in
            guard let self,
                  version == cameraSwitchVersion else {
                return
            }
            animateCameraSwitchFlip(version: version)
        }
    }

    func animateCameraSwitchFlip(version: UInt64) {
        var flipTransform = CATransform3DIdentity
        flipTransform.m34 = -1 / 600
        flipTransform = CATransform3DRotate(
            flipTransform,
            .pi,
            0,
            1,
            0
        )

        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            self.realtimeVideoView.layer.transform = flipTransform
            self.cameraSwitchBlurView.layer.transform = flipTransform
        } completion: { [weak self] _ in
            guard let self,
                  version == cameraSwitchVersion else {
                return
            }
            UIView.performWithoutAnimation {
                self.realtimeVideoView.layer.transform = CATransform3DIdentity
                self.cameraSwitchBlurView.layer.transform =
                    CATransform3DIdentity
            }
            hasCompletedCameraSwitchFlip = true
            finishCameraSwitchTransitionIfReady()
        }
    }

    func finishCameraSwitchTransitionIfReady() {
        guard !isCameraSwitchTransitionActive,
              hasCompletedCameraSwitchFlip else {
            return
        }
        let version = cameraSwitchVersion

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.cameraSwitchBlurView.alpha = 0
        } completion: { [weak self] _ in
            guard let self,
                  version == cameraSwitchVersion,
                  !isCameraSwitchTransitionActive else {
                return
            }
            cameraSwitchBlurView.effect = nil
            cameraSwitchBlurView.alpha = 1
            cameraSwitchBlurView.isHidden = true
            hasCompletedCameraSwitchFlip = false
        }
    }
}
