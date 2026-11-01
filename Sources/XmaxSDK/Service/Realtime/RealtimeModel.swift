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

    /// The X2.1 TRTC model, sharing X2.1 media settings. Select the RTC provider separately.
    case x2_1_trtc = "x2.1-trtc"

    /// A temporary X2.1 model routed to the internal development session service.
    case x2_1_debug = "x2.1-debug"

    /// The model's display name.
    public var displayName: String {
        switch self {
        case .x2_1:
            "X2.1"
        case .x2_1_trtc:
            "X2.1 TRTC"
        case .x2_1_debug:
            "X2.1 Debug"
        }
    }

    /// Overrides the regional session endpoint only for the temporary development model.
    var sessionApiBaseURL: URL? {
        switch self {
        case .x2_1, .x2_1_trtc:
            nil
        case .x2_1_debug:
            URL(string: "https://dev.22duck.cn/open/api/v1")!
        }
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
