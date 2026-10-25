//
//  VideoOrientationObserver.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import UIKit

/// Observes window rotation through a child view controller.
@MainActor
final class VideoOrientationObserver: UIViewController {

    /// The video view receiving window orientation changes.
    private weak var videoView: XmaxRealtimeVideoView?

    /// The physical device orientation provider.
    private let deviceOrientation: () -> UIDeviceOrientation

    /// Whether a portrait-landscape transition is active.
    private(set) var isTransitioning = false

    /// Whether this observer began device orientation notifications.
    private var generatesOrientationNotifications = false

    /// Creates a window rotation observer.
    ///
    /// - Parameters:
    ///   - videoView: The video view receiving early orientation updates.
    ///   - deviceOrientation: The physical device orientation provider.
    init(
        videoView: XmaxRealtimeVideoView,
        deviceOrientation: @escaping () -> UIDeviceOrientation = {
            UIDevice.current.orientation
        }
    ) {
        self.videoView = videoView
        self.deviceOrientation = deviceOrientation
        super.init(
            nibName: nil,
            bundle: nil
        )
    }

    /// Creates an orientation observer from an archive.
    ///
    /// - Parameter coder: The view controller archive decoder.
    required init?(
        coder: NSCoder
    ) {
        deviceOrientation = {
            UIDevice.current.orientation
        }
        super.init(coder: coder)
    }

    /// Ends device notifications started by this observer.
    deinit {
        if generatesOrientationNotifications {
            Task { @MainActor in
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
    }

    /// Creates a transparent, noninteractive observation view.
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    /// Updates device notifications when parent attachment changes.
    ///
    /// - Parameter parent: The new parent, or `nil` on removal.
    override func didMove(
        toParent parent: UIViewController?
    ) {
        super.didMove(toParent: parent)
        if parent != nil, !generatesOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            generatesOrientationNotifications = true
        } else if parent == nil, generatesOrientationNotifications {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            generatesOrientationNotifications = false
        }
    }

    /// Reports target orientation before rotation and actual orientation afterward.
    ///
    /// - Parameters:
    ///   - size: The container dimensions after rotation.
    ///   - coordinator: The system rotation transition coordinator.
    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(
            to: size,
            with: coordinator
        )
        guard !coordinator.targetTransform.isIdentity else {
            return
        }

        isTransitioning = true
        let target = Self.interfaceOrientation(for: deviceOrientation())
        if let target,
            target.isLandscape == (size.width > size.height)
        {
            videoView?.updateInterfaceOrientation(target)
        }

        let registered = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else {
                return
            }
            isTransitioning = false
            videoView?.updateWindowOrientation()
        }
        if !registered {
            isTransitioning = false
        }
    }

    /// Converts device orientation to interface orientation.
    ///
    /// - Parameter orientation: The device orientation.
    ///
    /// - Returns: The interface orientation, or `nil` if flat or unknown.
    static func interfaceOrientation(
        for orientation: UIDeviceOrientation
    ) -> UIInterfaceOrientation? {
        switch orientation {
        case .portrait:
            .portrait
        case .portraitUpsideDown:
            .portraitUpsideDown
        case .landscapeLeft:
            .landscapeRight
        case .landscapeRight:
            .landscapeLeft
        default:
            nil
        }
    }
}
