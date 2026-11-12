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

    /// The X2.1 Flash realtime generation model.
    case x2_1_flash = "x2.1-flash"

    /// The model's display name.
    public var displayName: String {
        switch self {
        case .x2_1: "X2.1"
        case .x2_1_flash: "X2.1 Flash"
        }
    }

    /// The supported frame dimensions and recommended frame rates.
    ///
    /// Camera dimensions must match an entry exactly. Images and videos retain their media aspect
    /// ratio and use the closest generation canvas. An empty array allows variable canvas
    /// dimensions, resolved using pixel limits and alignment.
    public var supportedVideoFormats: [RealtimeVideoFormat] {
        let presets: [RealtimeCameraPreset]
        switch self {
        case .x2_1:
            presets = [
                .resolution1920x1080, .resolution1080x1920, .resolution1408x1408,
                .resolution1152x1536, .resolution1536x1152
            ]
        case .x2_1_flash:
            presets = [
                .resolution704x1280, .resolution1280x704, .resolution960x960,
                .resolution1024x768, .resolution768x1024
            ]
        }
        return presets.map(videoFormat(for:))
    }

    /// The minimum local media and uplink area, in pixels; also limits variable generation canvases.
    public var minimumInputPixels: Int {
        200000
    }

    /// The maximum local media area, in pixels; also limits variable generation canvases.
    public var maximumInputPixels: Int {
        switch self {
        case .x2_1: 2_100_000
        case .x2_1_flash: 960 * 960
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
        case .x2_1: videoFormat(for: .resolution1080x1920)
        case .x2_1_flash: videoFormat(for: .resolution704x1280)
        }
    }

    private func videoFormat(for preset: RealtimeCameraPreset) -> RealtimeVideoFormat {
        let size = preset.size
        return RealtimeVideoFormat(
            width: Int(size.width),
            height: Int(size.height),
            fps: defaultFrameRate
        )
    }
}
