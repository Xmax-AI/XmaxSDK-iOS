//
//  XmaxRealtimeDualVideo.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import SwiftUI

/// A SwiftUI view that overlays local and remote video tracks and switches between them.
@MainActor
public struct XmaxRealtimeDualVideo: UIViewRepresentable {

    /// The local preview track.
    public let localTrack: RealtimeVideoTrack?

    /// The remote generation track.
    public let remoteTrack: RealtimeVideoTrack?

    /// The video content mode.
    public let videoContentMode: VideoContentMode

    /// The remote video's fade-in duration, in seconds. The default is 0.3; zero disables animation.
    public let remoteVideoFadeInDuration: TimeInterval

    /// Whether remote trajectory interaction is enabled.
    public let isInteractionEnabled: Bool

    /// Creates a dual-track realtime video view.
    public init(
        localTrack: RealtimeVideoTrack?,
        remoteTrack: RealtimeVideoTrack?,
        videoContentMode: VideoContentMode = .fill,
        remoteVideoFadeInDuration: TimeInterval = 0.3,
        isInteractionEnabled: Bool = true
    ) {
        self.localTrack = localTrack
        self.remoteTrack = remoteTrack
        self.videoContentMode = videoContentMode
        self.remoteVideoFadeInDuration = remoteVideoFadeInDuration
        self.isInteractionEnabled = isInteractionEnabled
    }

    /// Creates the underlying UIKit video view.
    ///
    /// - Parameter context: The SwiftUI view creation context.
    ///
    /// - Returns: The realtime video view configured with local and remote tracks.
    public func makeUIView(
        context: Context
    ) -> XmaxRealtimeDualVideoView {
        XmaxRealtimeDualVideoView(
            localTrack: localTrack,
            remoteTrack: remoteTrack,
            videoContentMode: videoContentMode,
            remoteVideoFadeInDuration: remoteVideoFadeInDuration,
            isInteractionEnabled: isInteractionEnabled
        )
    }

    /// Updates the UIKit view's tracks and display settings.
    ///
    /// - Parameters:
    ///   - view: The SDK video view to update.
    ///   - context: The SwiftUI view update context.
    public func updateUIView(
        _ view: XmaxRealtimeDualVideoView,
        context: Context
    ) {
        view.videoContentMode = videoContentMode
        view.remoteVideoFadeInDuration = remoteVideoFadeInDuration
        view.isInteractionEnabled = isInteractionEnabled
        view.localTrack = localTrack
        view.remoteTrack = remoteTrack
    }

    /// Detaches video tracks when SwiftUI removes the view.
    ///
    /// - Parameters:
    ///   - view: The SDK view being removed.
    ///   - coordinator: The SwiftUI coordinator, with no additional state.
    public static func dismantleUIView(
        _ view: XmaxRealtimeDualVideoView,
        coordinator: Void
    ) {
        view.localTrack = nil
        view.remoteTrack = nil
    }
}
