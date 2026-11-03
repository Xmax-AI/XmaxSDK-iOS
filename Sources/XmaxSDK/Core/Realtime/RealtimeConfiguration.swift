//
//  RealtimeConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The model, frame interpolation, and adaptive quality settings for a realtime manager.
public struct RealtimeConfiguration: Equatable, Sendable {

    /// The model used for realtime generation.
    public let model: RealtimeModel

    /// Whether remote frame interpolation is initially enabled.
    public let isFrameInterpolationEnabled: Bool

    /// Whether uplink and downlink quality levels adapt automatically.
    ///
    /// When disabled, each connection starts at L1. Manual changes remain available.
    public let isAdaptiveQualityEnabled: Bool

    /// Creates a realtime configuration.
    public init(
        model: RealtimeModel,
        isFrameInterpolationEnabled: Bool = true,
        isAdaptiveQualityEnabled: Bool = true
    ) {
        self.model = model
        self.isFrameInterpolationEnabled = isFrameInterpolationEnabled
        self.isAdaptiveQualityEnabled = isAdaptiveQualityEnabled
    }
}
