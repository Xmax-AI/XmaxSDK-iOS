//
//  MediaServicing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

/// Media sizing rules and frame interpolation capabilities for a realtime model.
public protocol MediaServicing: Sendable {

    /// The model defining media rules.
    var model: RealtimeModel {
        get
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
    ) throws -> CGSize

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
    ) throws -> CGSize

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
    ) throws -> CGSize

    /// Checks device interpolation support for video dimensions.
    ///
    /// - Parameter size: The received video dimensions used for interpolation.
    ///
    /// - Returns: `true` if the system, device, and video format support interpolation.
    func supportsFrameInterpolation(
        for size: CGSize
    ) -> Bool
}
