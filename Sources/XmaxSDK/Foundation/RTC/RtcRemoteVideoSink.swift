//
//  RtcRemoteVideoSink.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import AgoraRtcKit

/// Copies Agora decoded frames into buffers safe for asynchronous rendering.
final class RtcRemoteVideoSink: NSObject, AgoraVideoFrameDelegate, @unchecked Sendable {

    /// Resolves the listener bound when the native frame arrives.
    private let listenerForFrame: @Sendable (UInt, String) -> RtcRemoteVideoFrameListener?

    /// Owns copied output buffers independently of native callback storage.
    private let copier = RtcPixelBufferCopier()

    /// Creates a remote decoded frame receiver.
    init(
        listenerForFrame: @escaping @Sendable (UInt, String) -> RtcRemoteVideoFrameListener?
    ) {
        self.listenerForFrame = listenerForFrame
    }

    /// Requests decoded frames as NV12 pixel buffers.
    ///
    /// - Returns: The NV12 video format.
    func getVideoFormatPreference() -> AgoraVideoFormat {
        .cvPixelNV12
    }

    /// Requests decoded frames before RTC rendering.
    ///
    /// - Returns: The pre-render frame observation position.
    func getObservedFramePosition() -> AgoraVideoFramePosition {
        .preRenderer
    }

    /// Requests read-only frame callbacks.
    ///
    /// - Returns: The read-only processing mode.
    func getVideoFrameProcessMode() -> AgoraVideoFrameProcessMode {
        .readOnly
    }

    /// Requests rotation be applied to pixels before delivery.
    ///
    /// - Returns: Always `true`.
    func getRotationApplied() -> Bool {
        true
    }

    /// Requests unmirrored decoded frames.
    ///
    /// - Returns: Always `false`.
    func getMirrorApplied() -> Bool {
        false
    }

    /// Delivers a copy of a decoded frame for asynchronous use.
    ///
    /// - Parameters:
    ///   - frame: The Agora decoded frame.
    ///   - uid: The remote numeric UID.
    ///   - channelId: The frame's channel identifier.
    ///
    /// - Returns: Always `true`, allowing RTC processing to continue.
    func onRenderVideoFrame(
        _ frame: AgoraOutputVideoFrame,
        uid: UInt,
        channelId: String
    ) -> Bool {
        guard let listener = listenerForFrame(uid, channelId),
            let source = frame.pixelBuffer,
            let buffer = copier.copy(source)
        else {
            return true
        }

        listener(
            RealtimeVideoFrame(
                pixelBuffer: buffer,
                presentationTimeStamp: CMTime(
                    value: frame.renderTimeMs,
                    timescale: 1000
                )
            )
        )
        return true
    }

}
