//
//  RealtimeModel.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import CoreGraphics

/// A realtime generation model supported by XmaxSDK.
public enum RealtimeModel: String, CaseIterable, Sendable {

    /// The X2.1 realtime generation model.
    case x2_1 = "x2.1"

    /// The model's display name.
    public var displayName: String {
        "X2.1"
    }

    /// The supported frame dimensions and recommended frame rates.
    ///
    /// Camera dimensions must match an entry exactly. Images and videos retain their media aspect
    /// ratio and use the closest generation canvas. An empty array allows variable canvas
    /// dimensions, resolved using pixel limits and alignment.
    public var supportedVideoFormats: [RealtimeVideoFormat] {
        [
            RealtimeVideoFormat(
                width: 1920,
                height: 1080,
                fps: defaultFrameRate
            ),
            RealtimeVideoFormat(
                width: 1080,
                height: 1920,
                fps: defaultFrameRate
            ),
            RealtimeVideoFormat(
                width: 1408,
                height: 1408,
                fps: defaultFrameRate
            ),
            RealtimeVideoFormat(
                width: 1152,
                height: 1536,
                fps: defaultFrameRate
            ),
            RealtimeVideoFormat(
                width: 1536,
                height: 1152,
                fps: defaultFrameRate
            )
        ]
    }

    /// The minimum local media and uplink area, in pixels; also limits variable generation canvases.
    public var minimumInputPixels: Int {
        200000
    }

    /// The maximum local media area, in pixels; also limits variable generation canvases.
    public var maximumInputPixels: Int {
        2100000
    }

    /// The dimension alignment, in pixels, used to resolve variable generation canvases.
    public var inputSizeAlignment: Int {
        32
    }

    /// The frame rate used for image and video output and the default camera format.
    public var defaultFrameRate: Int {
        30
    }

    /// The default camera capture format.
    public var defaultCameraVideoFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(
            width: 1080,
            height: 1920,
            fps: defaultFrameRate
        )
    }
}
