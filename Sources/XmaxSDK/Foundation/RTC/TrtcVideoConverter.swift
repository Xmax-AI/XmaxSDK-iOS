//
//  TrtcVideoConverter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Accelerate
import CoreVideo
import Foundation
@preconcurrency import TXLiteAVSDK_TRTC

/// Owns the pixel buffer borrowed by a native TRTC input frame.
final class TrtcVideoFrame {

    /// The native frame whose pixel buffer must remain alive during submission.
    let value = TRTCVideoFrame()

    /// The independently owned pixels.
    let buffer: CVPixelBuffer

    /// Copies SDK planes into NV12 or BGRA, applying encoder mirroring before rotation.
    init(
        frame: VideoFrame,
        mirrored: Bool
    ) throws {
        let width = frame.format.width
        let height = frame.format.height
        let yuv = [.nv12, .nv21, .i420].contains(frame.format.pixelFormat)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
            !yuv || (width.isMultiple(of: 2) && height.isMultiple(of: 2))
        else {
            throw Self.invalidFrame()
        }
        let layout: [(Int, Int)] =
            frame.format.pixelFormat == .i420
            ? [(width, height), (width / 2, height / 2), (width / 2, height / 2)]
            : yuv ? [(width, height), (width, height / 2)] : [(width * 4, height)]
        guard frame.planes.count == layout.count else { throw Self.invalidFrame() }
        for (plane, (bytes, rows)) in zip(frame.planes, layout) {
            guard plane.stride >= bytes, plane.byteLength >= bytes,
                rows - 1 <= (plane.byteLength - bytes) / plane.stride
            else { throw Self.invalidFrame() }
        }
        let format =
            yuv ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        var output: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            nil,
            width,
            height,
            format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
                as CFDictionary,
            &output
        )
        guard result == kCVReturnSuccess, let output else { throw Self.invalidFrame() }
        buffer = output
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw Self.invalidFrame()
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let verticalMirror =
            mirrored && (frame.rotation == .rotation90 || frame.rotation == .rotation270)
        let horizontalMirror = mirrored && !verticalMirror
        for planeIndex in 0..<(yuv ? 2 : 1) {
            let rows = planeIndex == 1 ? height / 2 : height
            let pixels = planeIndex == 1 ? width / 2 : width
            let unit = yuv ? (planeIndex == 1 ? 2 : 1) : 4
            let stride =
                yuv
                ? CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
                : CVPixelBufferGetBytesPerRow(buffer)
            let base =
                yuv
                ? CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
                : CVPixelBufferGetBaseAddress(buffer)
            guard let base else { throw Self.invalidFrame() }
            // Read every plane through Data's scoped pointer to preserve its ownership contract.
            let source = frame.planes[planeIndex]
            try source.data.withUnsafeBytes { sourceBytes in
                let src = sourceBytes.baseAddress!.advanced(by: source.byteOffset)
                    .assumingMemoryBound(to: UInt8.self)
                if horizontalMirror
                    && (frame.format.pixelFormat == .nv12 || frame.format.pixelFormat == .bgra)
                {
                    var input = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: src),
                        height: vImagePixelCount(rows),
                        width: vImagePixelCount(pixels),
                        rowBytes: source.stride
                    )
                    var output = vImage_Buffer(
                        data: base,
                        height: vImagePixelCount(rows),
                        width: vImagePixelCount(pixels),
                        rowBytes: stride
                    )
                    let status: vImage_Error
                    switch unit {
                    case 1:
                        status = vImageHorizontalReflect_Planar8(
                            &input,
                            &output,
                            vImage_Flags(kvImageNoFlags)
                        )
                    case 2:
                        status = vImageHorizontalReflect_Planar16U(
                            &input,
                            &output,
                            vImage_Flags(kvImageNoFlags)
                        )
                    default:
                        status = vImageHorizontalReflect_ARGB8888(
                            &input,
                            &output,
                            vImage_Flags(kvImageNoFlags)
                        )
                    }
                    guard status == kvImageNoError else { throw Self.invalidFrame() }
                    return
                }
                for row in 0..<rows {
                    let sourceRow = verticalMirror ? rows - 1 - row : row
                    let dst = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                    if !horizontalMirror
                        && (frame.format.pixelFormat == .nv12 || frame.format.pixelFormat == .bgra
                            || (yuv && planeIndex == 0))
                    {
                        memcpy(dst, src.advanced(by: sourceRow * source.stride), pixels * unit)
                        continue
                    }
                    for column in 0..<pixels {
                        let sourceColumn = horizontalMirror ? pixels - 1 - column : column
                        let offset =
                            sourceRow * source.stride + sourceColumn
                            * (frame.format.pixelFormat == .i420 ? 1 : unit)
                        if frame.format.pixelFormat == .i420 && planeIndex == 1 {
                            dst[column * 2] = src[offset]
                            let v = frame.planes[2]
                            dst[column * 2 + 1] =
                                v.data[
                                    v.data.startIndex + v.byteOffset + sourceRow * v.stride
                                        + sourceColumn
                                ]
                        } else if frame.format.pixelFormat == .nv21 && planeIndex == 1 {
                            dst[column * 2] = src[offset + 1]
                            dst[column * 2 + 1] = src[offset]
                        } else if frame.format.pixelFormat == .rgba {
                            dst[column * 4] = src[offset + 2]
                            dst[column * 4 + 1] = src[offset + 1]
                            dst[column * 4 + 2] = src[offset]
                            dst[column * 4 + 3] = src[offset + 3]
                        } else if frame.format.pixelFormat == .argb {
                            dst[column * 4] = src[offset + 3]
                            dst[column * 4 + 1] = src[offset + 2]
                            dst[column * 4 + 2] = src[offset + 1]
                            dst[column * 4 + 3] = src[offset]
                        } else {
                            memcpy(dst.advanced(by: column * unit), src.advanced(by: offset), unit)
                        }
                    }
                }
            }
        }
        value.pixelFormat = yuv ? ._NV12 : ._32BGRA
        value.bufferType = .pixelBuffer
        value.pixelBuffer = buffer
        value.width = UInt32(width)
        value.height = UInt32(height)
        updateMetadata(frame)
    }

    /// Updates timing while reusing explicitly unchanged pixels.
    func updateMetadata(
        _ frame: VideoFrame
    ) {
        value.timestamp = UInt64(frame.timestampUs / 1000)
        value.rotation = TRTCVideoRotation(rawValue: frame.rotation.rawValue / 90) ?? ._0
    }

    /// Describes unsupported dimensions or truncated pixel planes.
    private static func invalidFrame() -> XmaxError {
        XmaxError(
            code: .invalidConfiguration,
            message: "Invalid TRTC video frame dimensions or pixel planes"
        )
    }
}
