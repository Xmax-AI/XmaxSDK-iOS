//
//  RtcPixelBufferCopier.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreVideo
import Foundation

/// Copies borrowed NV12 frames into independently owned pooled buffers.
final class RtcPixelBufferCopier: @unchecked Sendable {

    /// The lock protecting the remote pixel buffer pool.
    private let lock = NSLock()

    /// The reusable remote frame buffer pool.
    private var pool: CVPixelBufferPool?

    /// The current pool dimensions, in pixels.
    private var dimensions = CGSize.zero

    /// The current pool pixel format.
    private var pixelFormat: OSType = 0

    /// Copies a frame while serializing access to the allocation pool.
    func copy(
        _ source: CVPixelBuffer
    ) -> CVPixelBuffer? {
        lock.withLock { copyLocked(source) }
    }

    /// Copies biplanar pixels and attachments into an owned buffer.
    ///
    /// - Parameter source: The source pixel buffer.
    ///
    /// - Returns: An owned copy, or `nil` if allocation fails or the layout is unsupported.
    private func copyLocked(
        _ source: CVPixelBuffer
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let size = CGSize(
            width: width,
            height: height
        )
        let format = CVPixelBufferGetPixelFormatType(source)
        guard CVPixelBufferGetPlaneCount(source) == 2 else {
            return nil
        }

        if pool == nil || dimensions != size || pixelFormat != format {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            guard
                CVPixelBufferPoolCreate(
                    nil,
                    nil,
                    attributes as CFDictionary,
                    &pool
                ) == kCVReturnSuccess
            else {
                return nil
            }

            dimensions = size
            pixelFormat = format
        }

        guard let pool else {
            return nil
        }

        var output: CVPixelBuffer?
        guard
            CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &output
            ) == kCVReturnSuccess,
            let output
        else {
            return nil
        }

        CVPixelBufferLockBaseAddress(
            source,
            .readOnly
        )
        CVPixelBufferLockBaseAddress(
            output,
            []
        )
        defer {
            CVPixelBufferUnlockBaseAddress(
                output,
                []
            )
            CVPixelBufferUnlockBaseAddress(
                source,
                .readOnly
            )
        }

        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard
                let src = CVPixelBufferGetBaseAddressOfPlane(
                    source,
                    plane
                ),
                let dst = CVPixelBufferGetBaseAddressOfPlane(
                    output,
                    plane
                )
            else {
                return nil
            }

            let srcStride = CVPixelBufferGetBytesPerRowOfPlane(
                source,
                plane
            )
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(
                output,
                plane
            )
            let bytes = min(
                srcStride,
                dstStride
            )

            for row
                in 0..<CVPixelBufferGetHeightOfPlane(
                    source,
                    plane
                )
            {
                memcpy(
                    dst.advanced(by: row * dstStride),
                    src.advanced(by: row * srcStride),
                    bytes
                )
            }
        }

        CVBufferPropagateAttachments(
            source,
            output
        )
        return output
    }
}
