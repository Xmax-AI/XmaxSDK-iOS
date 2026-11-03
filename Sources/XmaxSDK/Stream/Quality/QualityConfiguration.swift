//
//  QualityConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The media baseline and directional quality levels for a connection.
struct QualityConfiguration: Sendable {

    /// The resolved media baseline, unchanged by quality adaptation.
    let baseline: RealtimeVideoFormat

    /// The current uplink quality level.
    let uplinkLevel: RealtimeQualityLevel

    /// The target downlink quality level.
    let downlinkLevel: RealtimeQualityLevel

    /// The minimum uplink area, in pixels.
    let minimumInputPixels: Int

    /// The encoding format for the current uplink level.
    var uplink: RealtimeVideoFormat {
        QualityVideoFormat.resolve(
            baseline,
            level: uplinkLevel,
            downlink: false,
            minimumInputPixels: minimumInputPixels
        )
    }

    /// The maximum returned format for the current downlink level.
    var downlink: RealtimeVideoFormat {
        QualityVideoFormat.resolve(
            baseline,
            level: downlinkLevel,
            downlink: true
        )
    }
}

/// The directional quality proposals for one sample; `nil` leaves a direction unchanged.
struct QualityChange: Sendable {

    /// The proposed uplink level.
    let uplink: RealtimeQualityLevel?

    /// The proposed downlink level.
    let downlink: RealtimeQualityLevel?
}
