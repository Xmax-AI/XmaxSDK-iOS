//
//  RealtimeCameraPreset.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

/// A camera resolution preset whose availability depends on the selected model.
public enum RealtimeCameraPreset: CaseIterable, Sendable {

    /// A landscape 16:9 frame.
    case resolution1920x1080

    /// A portrait 9:16 frame.
    case resolution1080x1920

    /// A square frame.
    case resolution1408x1408

    /// A portrait 3:4 frame.
    case resolution1152x1536

    /// A landscape 4:3 frame.
    case resolution1536x1152

    /// A portrait 11:20 frame for X2.1 Flash.
    case resolution704x1280

    /// A landscape 20:11 frame for X2.1 Flash.
    case resolution1280x704

    /// A square frame for X2.1 Flash.
    case resolution960x960

    /// A landscape 4:3 frame for X2.1 Flash.
    case resolution1024x768

    /// A portrait 3:4 frame for X2.1 Flash.
    case resolution768x1024

    /// The frame dimensions, in pixels.
    public var size: CGSize {
        switch self {
        case .resolution1920x1080:
            CGSize(
                width: 1920,
                height: 1080
            )
        case .resolution1080x1920:
            CGSize(
                width: 1080,
                height: 1920
            )
        case .resolution1408x1408:
            CGSize(
                width: 1408,
                height: 1408
            )
        case .resolution1152x1536:
            CGSize(
                width: 1152,
                height: 1536
            )
        case .resolution1536x1152:
            CGSize(
                width: 1536,
                height: 1152
            )
        case .resolution704x1280:
            CGSize(width: 704, height: 1280)
        case .resolution1280x704:
            CGSize(width: 1280, height: 704)
        case .resolution960x960:
            CGSize(width: 960, height: 960)
        case .resolution1024x768:
            CGSize(width: 1024, height: 768)
        case .resolution768x1024:
            CGSize(width: 768, height: 1024)
        }
    }
}
