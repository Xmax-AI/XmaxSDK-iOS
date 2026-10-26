//
//  MediaService.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import Foundation

/// The sizing and capability rules for local media, generation canvases, and returned media.
final class MediaService: MediaServicing, Sendable {

    /// The generation model defining sizing rules.
    let model: RealtimeModel

    /// The maximum interpolation pixel area.
    private static let maximumFrameInterpolationPixels = 900000

    /// Creates a media service for a model.
    init(
        model: RealtimeModel = .x2_1
    ) {
        self.model = model
    }

    /// Resolves local media dimensions and validates camera resolution buckets.
    ///
    /// - Parameters:
    ///   - sourceMediaSize: The requested camera dimensions or the source image or video's oriented
    ///     integer dimensions.
    ///   - source: The media source. Camera dimensions must match a configured model bucket.
    ///
    /// - Returns: Dimensions aligned to 4 within the model's area limits, upscaling or downscaling
    ///   as needed and preserving exact aspect ratio when possible.
    ///
    /// - Throws: An error if dimensions are invalid or a camera bucket does not match.
    func resolveMediaSize(
        _ sourceMediaSize: CGSize,
        source: RealtimeMediaSource
    ) throws -> CGSize {
        guard let width = Self.integralDimension(sourceMediaSize.width),
            let height = Self.integralDimension(sourceMediaSize.height)
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Media dimensions must be positive integers"
            )
        }

        let buckets = model.supportedVideoFormats.map(\.size)
        if source == .camera, !buckets.isEmpty, !buckets.contains(sourceMediaSize) {
            let supportedSizes = buckets.map {
                "\(Int($0.width))×\(Int($0.height))"
            }.joined(separator: ", ")
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Model \(model.rawValue) does not support camera resolution "
                    + "\(width)×\(height). Supported resolutions: \(supportedSizes)"
            )
        }

        let pixels = Double(width) * Double(height)
        let pixelLimits = model.minimumInputPixels...model.maximumInputPixels
        let targetPixels = min(max(pixels, Double(pixelLimits.lowerBound)), Double(pixelLimits.upperBound))
        return try alignedSize(
            width: width,
            height: height,
            scale: sqrt(targetPixels / pixels),
            alignment: 4,
            pixelLimits: pixelLimits
        )
    }

    /// Selects the closest generation canvas without changing local media dimensions.
    ///
    /// - Parameter resolvedMediaSize: The resolved local media dimensions.
    ///
    /// - Returns: The closest model bucket, or dimensions satisfying model area and alignment
    ///   rules.
    ///
    /// - Throws: An error if media dimensions are invalid.
    func resolveGenerationSize(
        _ resolvedMediaSize: CGSize
    ) throws -> CGSize {
        guard resolvedMediaSize.width.isFinite, resolvedMediaSize.height.isFinite,
            resolvedMediaSize.width > 0, resolvedMediaSize.height > 0
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Media dimensions must be positive"
            )
        }

        let aspect = resolvedMediaSize.width / resolvedMediaSize.height
        if let bucket = model.supportedVideoFormats.map(\.size).min(
            by: {
                abs(log(aspect / ($0.width / $0.height)))
                    < abs(log(aspect / ($1.width / $1.height)))
            }
        ) {
            return bucket
        }

        let size = try validatedSize(resolvedMediaSize)
        let pixels = Double(size.width) * Double(size.height)
        let scale: Double
        let rounding: (Double) -> Double

        if pixels < Double(model.minimumInputPixels) {
            scale = sqrt(Double(model.minimumInputPixels) / pixels)
            rounding = ceil
        } else if pixels > Double(model.maximumInputPixels) {
            scale = sqrt(Double(model.maximumInputPixels) / pixels)
            rounding = floor
        } else {
            scale = 1
            rounding = round
        }

        let alignment = Double(model.inputSizeAlignment)
        let width = max(
            Int(rounding(Double(size.width) * scale / alignment)) * model.inputSizeAlignment,
            model.inputSizeAlignment
        )
        let height = max(
            Int(rounding(Double(size.height) * scale / alignment)) * model.inputSizeAlignment,
            model.inputSizeAlignment
        )
        let alignedPixels = width * height
        if (model.minimumInputPixels...model.maximumInputPixels).contains(alignedPixels) {
            return CGSize(
                width: width,
                height: height
            )
        }

        // Alignment may cross the area boundary; select the closest valid candidate.
        return boundedAlignedSize(
            width: Double(size.width) * scale,
            height: Double(size.height) * scale,
            alignment: model.inputSizeAlignment,
            pixelLimits: model.minimumInputPixels...model.maximumInputPixels
        )
    }

    /// Resolves returned dimensions within quality and optional interpolation limits.
    ///
    /// - Parameters:
    ///   - resolvedMediaSize: The resolved local dimensions defining aspect ratio and the
    ///     no-upscaling boundary.
    ///   - maximumSize: The maximum downlink dimensions, allowing fractional pixels.
    ///   - frameInterpolationEnabled: Whether to cap the area at 900000 pixels, without checking
    ///     device capabilities.
    ///
    /// - Returns: Dimensions aligned to 4 within the limit, preserving exact aspect ratio when
    ///   possible and rounding down otherwise.
    ///
    /// - Throws: An `XmaxError` if dimensions are invalid or the limits cannot fit at least 4 × 4
    ///   pixels.
    func resolveTargetSize(
        _ resolvedMediaSize: CGSize,
        maximumSize: CGSize,
        frameInterpolationEnabled: Bool
    ) throws -> CGSize {
        guard let width = Self.integralDimension(resolvedMediaSize.width),
            let height = Self.integralDimension(resolvedMediaSize.height),
            maximumSize.width.isFinite, maximumSize.width > 0,
            maximumSize.height.isFinite, maximumSize.height > 0
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message:
                    "Source dimensions must be positive integers and target bounds must be positive and finite"
            )
        }

        var scale = min(
            1,
            min(
                Double(maximumSize.width) / Double(width),
                Double(maximumSize.height) / Double(height)
            )
        )
        let targetPixels = (Double(width) * scale) * (Double(height) * scale)
        if frameInterpolationEnabled, targetPixels > Double(Self.maximumFrameInterpolationPixels) {
            scale *= sqrt(Double(Self.maximumFrameInterpolationPixels) / targetPixels)
        }

        return try alignedSize(
            width: width,
            height: height,
            scale: scale,
            alignment: 4
        )
    }

    /// Checks device interpolation support for video dimensions.
    ///
    /// - Parameter size: The received video dimensions used for interpolation.
    ///
    /// - Returns: `true` if the system, device, and video format support interpolation.
    func supportsFrameInterpolation(
        for size: CGSize
    ) -> Bool {
        guard Self.supportsFrameInterpolationSize(size) else {
            return false
        }
        return FrameInterpolationSupport.supports(size: size)
    }

    /// Checks integer dimensions against the interpolation pixel limit.
    ///
    /// - Parameter size: The video dimensions, in pixels.
    ///
    /// - Returns: `true` if dimensions meet the pixel limit, independent of device capability.
    static func supportsFrameInterpolationSize(
        _ size: CGSize
    ) -> Bool {
        guard let width = integralDimension(size.width),
            let height = integralDimension(size.height)
        else {
            return false
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(
            by: height
        )
        return !overflow && pixelCount <= maximumFrameInterpolationPixels
    }
}

private extension MediaService {

    /// Resolves aligned dimensions at a requested scale, preferring exact aspect ratio.
    ///
    /// - Parameters:
    ///   - width: The original integer pixel width.
    ///   - height: The original integer pixel height.
    ///   - scale: The requested uniform scale.
    ///   - alignment: The required dimension alignment, in pixels.
    ///   - pixelLimits: Optional area bounds. Without bounds, alignment only rounds down.
    ///
    /// - Returns: Aligned dimensions satisfying the area bounds, preserving exact aspect ratio
    ///   when possible. Without bounds, dimensions do not exceed the requested scale.
    ///
    /// - Throws: An error if the scale limit cannot fit one alignment unit.
    func alignedSize(
        width: Int,
        height: Int,
        scale: Double,
        alignment: Int,
        pixelLimits: ClosedRange<Int>? = nil
    ) throws -> CGSize {
        // Use integer multiples of the reduced aspect ratio to avoid independent rounding.
        var divisor = width
        var remainder = height
        while remainder != 0 {
            (divisor, remainder) = (remainder, divisor % remainder)
        }

        let ratioWidth = width / divisor
        let ratioHeight = height / divisor
        var alignedScale = Int(floor(Double(divisor) * scale / Double(alignment))) * alignment
        if let pixelLimits {
            let ratioPixels = Double(ratioWidth) * Double(ratioHeight)
            let minimumScale = sqrt(Double(pixelLimits.lowerBound) / ratioPixels)
            let minimumAlignedScale = Int(ceil(minimumScale / Double(alignment))) * alignment
            alignedScale = max(alignedScale, minimumAlignedScale)
        }

        let exactWidth = Double(ratioWidth) * Double(alignedScale)
        let exactHeight = Double(ratioHeight) * Double(alignedScale)
        let maximumPixels = pixelLimits.map { Double($0.upperBound) } ?? .infinity
        if alignedScale >= alignment, exactWidth * exactHeight <= maximumPixels {
            return CGSize(
                width: exactWidth,
                height: exactHeight
            )
        }

        let alignedWidth = Int(floor(Double(width) * scale / Double(alignment))) * alignment
        let alignedHeight = Int(floor(Double(height) * scale / Double(alignment))) * alignment
        let alignedPixels = Double(alignedWidth) * Double(alignedHeight)
        if let pixelLimits,
            alignedPixels < Double(pixelLimits.lowerBound) || alignedPixels > Double(pixelLimits.upperBound)
        {
            return boundedAlignedSize(
                width: Double(width) * scale,
                height: Double(height) * scale,
                alignment: alignment,
                pixelLimits: pixelLimits
            )
        }

        guard alignedWidth >= alignment, alignedHeight >= alignment else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "No aligned video size is available within the size limits"
            )
        }

        return CGSize(
            width: alignedWidth,
            height: alignedHeight
        )
    }

    /// Selects the closest dimensions satisfying area and alignment limits.
    ///
    /// - Parameters:
    ///   - width: The scaled target width, in pixels.
    ///   - height: The scaled target height, in pixels.
    ///   - alignment: The required dimension alignment, in pixels.
    ///   - pixelLimits: The inclusive output area bounds, in pixels.
    ///
    /// - Returns: The valid dimensions with the smallest relative width and height error.
    func boundedAlignedSize(
        width: Double,
        height: Double,
        alignment: Int,
        pixelLimits: ClosedRange<Int>
    ) -> CGSize {
        let unitPixels = alignment * alignment
        let minimumUnits = (pixelLimits.lowerBound + unitPixels - 1) / unitPixels
        let maximumUnits = pixelLimits.upperBound / unitPixels
        var bestSize = CGSize.zero
        var bestDistance = Double.infinity

        for widthUnits in 1...maximumUnits {
            let minimumHeight = (minimumUnits + widthUnits - 1) / widthUnits
            let maximumHeight = maximumUnits / widthUnits
            guard minimumHeight <= maximumHeight else {
                continue
            }

            let heightUnits = min(
                max(
                    Int((height / Double(alignment)).rounded()),
                    minimumHeight
                ),
                maximumHeight
            )
            let candidateWidth = Double(widthUnits * alignment)
            let candidateHeight = Double(heightUnits * alignment)
            let distance =
                pow(
                    (candidateWidth - width) / width,
                    2
                )
                + pow(
                    (candidateHeight - height) / height,
                    2
                )
            if distance < bestDistance {
                bestDistance = distance
                bestSize = CGSize(
                    width: candidateWidth,
                    height: candidateHeight
                )
            }
        }

        return bestSize
    }

    /// Validates media dimensions and rounds to at least one pixel.
    ///
    /// - Parameter size: The media dimensions to validate.
    ///
    /// - Returns: The positive integer media dimensions.
    ///
    /// - Throws: A configuration error if dimensions are nonfinite, nonpositive, or out of range.
    func validatedSize(
        _ size: CGSize
    ) throws -> CGSize {
        guard size.width.isFinite,
            size.height.isFinite,
            size.width > 0,
            size.height > 0,
            size.width < CGFloat(Int.max),
            size.height < CGFloat(Int.max)
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Image width and height must be finite numbers greater than zero"
            )
        }

        return CGSize(
            width: max(
                size.width.rounded(),
                1
            ),
            height: max(
                size.height.rounded(),
                1
            )
        )
    }

    /// Converts a valid pixel dimension to a positive integer.
    ///
    /// - Parameter value: The pixel dimension to validate.
    ///
    /// - Returns: The positive integer, or `nil` if nonfinite, nonintegral, or out of range.
    static func integralDimension(
        _ value: CGFloat
    ) -> Int? {
        guard value.isFinite,
            value > 0,
            value < CGFloat(Int.max)
        else {
            return nil
        }
        let roundedValue = value.rounded()
        guard roundedValue == value else {
            return nil
        }
        return Int(roundedValue)
    }
}
