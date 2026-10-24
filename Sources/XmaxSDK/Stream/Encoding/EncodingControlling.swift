//
//  EncodingControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// An interface for realtime encoder configuration.
protocol EncodingControlling: Sendable {

    /// Validates and applies a resolved encoder configuration.
    ///
    /// - Parameter videoFormat: The 4-aligned dimensions, frame rate, optional bitrate bounds, and
    ///   encoding preference.
    ///
    /// - Throws: An error if the format, bitrate resolution, or RTC configuration fails.
    func configure(
        _ videoFormat: RealtimeVideoFormat
    ) throws
}
