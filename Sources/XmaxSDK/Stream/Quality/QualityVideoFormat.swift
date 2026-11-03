//
//  QualityVideoFormat.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Resolves transport levels without changing capture or generation formats.
enum QualityVideoFormat {

    /// The per-level dimension scale factors.
    static let scales: [Double] = [1, 0.9, 0.75, 0.6, 0.5]

    /// The per-level target frame rates.
    static let frameRates = [30, 24, 24, 20, 16]

    /// Resolves downlink dimension limits before alignment or interpolation constraints.
    ///
    /// - Parameters:
    ///   - baseline: The media baseline, unchanged by adaptation.
    ///   - level: The target downlink quality level.
    ///
    /// - Returns: The aspect-preserving maximum dimensions, allowing fractional pixels.
    static func resolveDownlinkMaximumSize(
        _ baseline: RealtimeVideoFormat,
        level: RealtimeQualityLevel
    ) -> CGSize {
        let scale = sizeScale(
            baseline,
            level: level
        )
        return CGSize(
            width: Double(baseline.width) * scale,
            height: Double(baseline.height) * scale
        )
    }

    /// Resolves a transport format for a direction and level.
    ///
    /// - Parameters:
    ///   - baseline: The resolved local media baseline.
    ///   - level: The target quality level.
    ///   - downlink: Whether this is downlink. Downlink uses 24 fps; uplink does not exceed the
    ///     baseline rate.
    ///   - minimumInputPixels: The minimum uplink area, in pixels; ignored for downlink.
    ///
    /// - Returns: The resolved transport format; uplink dimensions are multiples of 4.
    static func resolve(
        _ baseline: RealtimeVideoFormat,
        level: RealtimeQualityLevel,
        downlink: Bool,
        minimumInputPixels: Int = 0
    ) -> RealtimeVideoFormat {
        let index = level.rawValue - 1
        let scale = sizeScale(
            baseline,
            level: level
        )
        let size = scaledSize(
            baseline.size,
            scale: scale,
            alignment: downlink ? 2 : 4,
            minimumPixels: downlink ? 0 : minimumInputPixels
        )
        return RealtimeVideoFormat(
            width: Int(size.width),
            height: Int(size.height),
            fps: downlink
                ? 24
                : min(
                    baseline.fps,
                    frameRates[index]
                ),
            minimumBitrate: downlink ? nil : baseline.minimumBitrate,
            maximumBitrate: downlink ? nil : baseline.maximumBitrate,
            encoderPreference: baseline.encoderPreference
        )
    }

    /// Downscales dimensions, preferring exact aspect ratio at the required alignment.
    ///
    /// - Parameters:
    ///   - size: The original integer pixel dimensions.
    ///   - scale: The requested dimension scale.
    ///   - alignment: The required multiple for each output dimension.
    ///   - minimumPixels: The minimum output area, capped at the source area to prevent upscaling.
    ///
    /// - Returns: Aligned dimensions respecting the minimum area without upscaling, preferring exact
    ///   aspect ratio.
    static func scaledSize(
        _ size: CGSize,
        scale: Double,
        alignment: Int,
        minimumPixels: Int = 0
    ) -> CGSize {
        let width = Int(size.width)
        let height = Int(size.height)
        var divisor = width
        var remainder = height
        while remainder != 0 {
            (divisor, remainder) = (remainder, divisor % remainder)
        }

        let pixels = Double(width) * Double(height)
        let minimumScale = sqrt(min(Double(max(0, minimumPixels)), pixels) / pixels)
        let minimumUnits = Int(ceil(Double(divisor) * minimumScale / Double(alignment))) * alignment
        let units = Int(floor(Double(divisor) * scale + 0.0000001)) / alignment * alignment
        let resolvedUnits = max(units, minimumUnits)
        if units >= alignment, resolvedUnits <= divisor {
            return CGSize(
                width: width / divisor * resolvedUnits,
                height: height / divisor * resolvedUnits
            )
        }

        return CGSize(
            width: max(
                alignment,
                max(
                    Int(floor(Double(width) * scale / Double(alignment))) * alignment,
                    Int(ceil(Double(width) * minimumScale / Double(alignment))) * alignment
                )
            ),
            height: max(
                alignment,
                max(
                    Int(floor(Double(height) * scale / Double(alignment))) * alignment,
                    Int(ceil(Double(height) * minimumScale / Double(alignment))) * alignment
                )
            )
        )
    }

    /// Resolves a scale retaining the minimum short edge without upscaling.
    ///
    /// - Parameters:
    ///   - baseline: The media baseline format.
    ///   - level: The target quality level.
    ///
    /// - Returns: The dimension scale, no greater than 1.
    private static func sizeScale(
        _ baseline: RealtimeVideoFormat,
        level: RealtimeQualityLevel
    ) -> Double {
        let index = level.rawValue - 1
        let shortSide = min(
            baseline.width,
            baseline.height
        )
        return max(
            scales[index],
            Double(
                min(
                    shortSide,
                    240
                )
            ) / Double(shortSide)
        )
    }
}
