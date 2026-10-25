//
//  VideoRenderBinding.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import UIKit

/// Binds a video track to a UIKit rendering view.
@MainActor
final class VideoRenderBinding {

    /// The operation attaching content with its content mode.
    private let attachHandler: (UIView, VideoContentMode) throws -> Void

    /// The operation detaching rendering resources.
    private let detachHandler: (UIView) throws -> Void

    /// The currently attached view.
    private weak var attachedView: UIView?

    /// Creates a track-to-view rendering binding.
    init(
        attachHandler: @escaping (UIView, VideoContentMode) throws -> Void,
        detachHandler: @escaping (UIView) throws -> Void
    ) {
        self.attachHandler = attachHandler
        self.detachHandler = detachHandler
    }

    /// Attaches content to a view after detaching the previous view.
    ///
    /// - Parameters:
    ///   - view: The new rendering view.
    ///   - contentMode: The video content mode.
    ///
    /// - Throws: An error if detaching or attaching fails.
    func attach(
        to view: UIView,
        contentMode: VideoContentMode
    ) throws {
        if let attachedView, attachedView !== view {
            try detachHandler(attachedView)
            self.attachedView = nil
        }

        try attachHandler(
            view,
            contentMode
        )
        attachedView = view
    }

    /// Detaches rendering only if the view is currently attached.
    ///
    /// - Parameter view: The view to detach.
    ///
    /// - Throws: An error if the underlying detach operation fails.
    func detach(
        from view: UIView
    ) throws {
        guard attachedView === view else {
            return
        }
        try detach()
    }

    /// Clears image preview and detaches rendering.
    ///
    /// - Throws: An error if the underlying detach operation fails.
    func detach() throws {
        guard let attachedView else {
            return
        }
        (attachedView as? XmaxRealtimeVideoView)?.clearImageFrame()
        try detachHandler(attachedView)
        self.attachedView = nil
    }
}

extension VideoRenderBinding {

    /// Creates a static image preview binding.
    ///
    /// - Parameter imageFrame: The image pixels to preview.
    convenience init(
        imageFrame: VideoFrame
    ) {
        self.init(
            attachHandler: { view, contentMode in
                guard let videoView = view as? XmaxRealtimeVideoView else {
                    throw XmaxError(
                        code: .invalidConfiguration,
                        message: "Image tracks require an XmaxRealtimeVideoView"
                    )
                }
                try videoView.displayImageFrame(
                    imageFrame,
                    contentMode: contentMode
                )
            },
            detachHandler: { view in
                (view as? XmaxRealtimeVideoView)?.clearImageFrame()
            }
        )
    }
}
