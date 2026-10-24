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

    /// The China preview of the X2.1.1 realtime generation model.
    case x2_1_1_preview_cn = "x2.1.1-preview-cn"

    /// The global preview of the X2.1.1 realtime generation model.
    case x2_1_1_preview_us = "x2.1.1-preview-us"

    /// The model's display name.
    public var displayName: String {
        switch self {
        case .x2_1_1_preview_cn:
            "X2.1.1-preview-cn"
        case .x2_1_1_preview_us:
            "X2.1.1-preview-us"
        }
    }

    /// The supported frame dimensions and recommended frame rates.
    ///
    /// Camera dimensions must match an entry exactly. Images and videos retain their media aspect
    /// ratio and use the closest generation canvas. An empty array allows variable canvas
    /// dimensions, resolved using pixel limits and alignment.
    public var supportedVideoFormats: [RealtimeVideoFormat] {
        switch self {
        case .x2_1_1_preview_cn, .x2_1_1_preview_us:
            [
                RealtimeVideoFormat(
                    width: 1024,
                    height: 1920,
                    fps: defaultFrameRate
                ),
                RealtimeVideoFormat(
                    width: 1920,
                    height: 1024,
                    fps: defaultFrameRate
                )
            ]
        }
    }

    /// The minimum local media and uplink area, in pixels; also limits variable generation canvases.
    public var minimumInputPixels: Int {
        200000
    }

    /// The maximum local media area, in pixels; also limits variable generation canvases.
    public var maximumInputPixels: Int {
        switch self {
        case .x2_1_1_preview_cn, .x2_1_1_preview_us:
            2100000
        }
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
        switch self {
        case .x2_1_1_preview_cn, .x2_1_1_preview_us:
            RealtimeVideoFormat(
                width: 1024,
                height: 1920,
                fps: defaultFrameRate
            )
        }
    }
}
