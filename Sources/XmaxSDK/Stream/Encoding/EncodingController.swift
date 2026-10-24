//
//  EncodingController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Applies RTC encoding settings for a realtime video format.
final class EncodingController: EncodingControlling, Sendable {

    /// The RTC encoder configuration target.
    private let rtcManager: any RtcManaging

    /// Creates a video encoding controller.
    init(
        rtcManager: any RtcManaging
    ) {
        self.rtcManager = rtcManager
    }

    /// Validates and applies a resolved encoder configuration. An unspecified minimum uses 500
    /// kbps, capped by the maximum.
    ///
    /// - Parameter videoFormat: The 4-aligned dimensions, frame rate, optional bitrate bounds, and
    ///   encoding preference.
    ///
    /// - Throws: An error if the format, bitrate resolution, or RTC configuration fails.
    func configure(
        _ videoFormat: RealtimeVideoFormat
    ) throws {
        try videoFormat.validate()
        guard videoFormat.width.isMultiple(of: 4), videoFormat.height.isMultiple(of: 4) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Uplink video width and height must be multiples of 4"
            )
        }

        let budget = try EncodingBitratePolicy.resolve(videoFormat)
        let maximum = budget.maximum
        let minimum =
            videoFormat.minimumBitrate
            ?? min(
                500,
                maximum
            )

        let encoderPreference: VideoEncodingConfiguration.EncoderPreference =
            switch videoFormat.encoderPreference {
            case .auto:
                .auto
            case .maintainFramerate:
                .maintainFramerate
            case .maintainQuality:
                .maintainQuality
            }

        try rtcManager.configureVideoEncoding(
            VideoEncodingConfiguration(
                width: videoFormat.width,
                height: videoFormat.height,
                frameRate: videoFormat.fps,
                minimumBitrate: minimum,
                maximumBitrate: maximum,
                encoderPreference: encoderPreference
            )
        )
    }
}
