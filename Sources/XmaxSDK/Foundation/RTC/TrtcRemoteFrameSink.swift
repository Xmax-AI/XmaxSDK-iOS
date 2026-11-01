//
//  TrtcRemoteFrameSink.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreImage
import CoreMedia
import Foundation
@preconcurrency import TXLiteAVSDK_TRTC

/// Copies borrowed TRTC output before delivering it to asynchronous SDK consumers.
final class TrtcRemoteFrameSink: NSObject, TRTCVideoRenderDelegate, TRTCAudioFrameDelegate,
    @unchecked Sendable
{

    /// Protects listener membership and subscription state independently of native engine calls.
    private let lock = NSLock()

    /// The current video listeners by RTC user ID.
    private var videoListeners: [String: RtcRemoteVideoFrameListener] = [:]

    /// The current audio listeners by RTC user ID.
    private var audioListeners: [String: RtcRemoteAudioFrameListener] = [:]

    /// The explicitly subscribed video users.
    private var videoUsers: Set<String> = []

    /// The explicitly subscribed audio users.
    private var audioUsers: Set<String> = []

    /// Copies unrotated native NV12 frames.
    private let copier = RtcPixelBufferCopier()

    /// Applies native orientation metadata to owned output pixels.
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Sets a video listener without retaining a native callback buffer.
    func setVideoListener(
        _ listener: RtcRemoteVideoFrameListener?,
        userID: String
    ) {
        lock.withLock { videoListeners[userID] = listener }
    }

    /// Sets a PCM listener for a generated remote stream.
    func setAudioListener(
        _ listener: RtcRemoteAudioFrameListener?,
        userID: String
    ) {
        lock.withLock { audioListeners[userID] = listener }
    }

    /// Gates delivery on explicit subscription.
    func setSubscription(
        userID: String,
        video: Bool,
        subscribed: Bool
    ) {
        lock.withLock {
            if video {
                if subscribed { videoUsers.insert(userID) } else { videoUsers.remove(userID) }
            } else {
                if subscribed { audioUsers.insert(userID) } else { audioUsers.remove(userID) }
            }
        }
    }

    /// Invalidates listeners before native room teardown.
    func close() {
        lock.withLock {
            videoListeners.removeAll()
            audioListeners.removeAll()
            videoUsers.removeAll()
            audioUsers.removeAll()
        }
    }

    /// Copies one main-stream frame, applying rotation before rendering or recording.
    func onRenderVideoFrame(
        _ frame: TRTCVideoFrame,
        userId: String?,
        streamType: TRTCVideoStreamType
    ) {
        guard streamType == .big, let userId,
            let listener = lock.withLock({
                videoUsers.contains(userId) ? videoListeners[userId] : nil
            }),
            let source = frame.pixelBuffer,
            frame.timestamp <= UInt64(Int64.max),
            let buffer = copyPixels(source, rotation: frame.rotation)
        else { return }
        listener(
            RealtimeVideoFrame(
                pixelBuffer: buffer,
                presentationTimeStamp: CMTime(value: Int64(frame.timestamp), timescale: 1000)
            )
        )
    }

    /// Copies remote PCM before TRTC reuses its callback storage.
    func onRemoteUserAudioFrame(
        _ frame: TRTCAudioFrame,
        userId: String
    ) {
        guard
            let listener = lock.withLock({
                audioUsers.contains(userId) ? audioListeners[userId] : nil
            }),
            (1...2).contains(frame.channels), frame.timestamp <= UInt64(Int64.max)
        else { return }
        let data = frame.data.withUnsafeBytes { Data($0) }
        listener(
            RtcRemoteAudioFrame(
                data: data,
                sampleRate: Int(frame.sampleRate.rawValue),
                channels: Int(frame.channels),
                samplesPerChannel: data.count / (Int(frame.channels) * 2),
                renderTimeMs: Int64(frame.timestamp)
            )
        )
    }

    /// Owns native pixels and normalizes orientation without scheduling work on the main actor.
    private func copyPixels(
        _ source: CVPixelBuffer,
        rotation: TRTCVideoRotation
    ) -> CVPixelBuffer? {
        guard rotation.rawValue != 0 else { return copier.copy(source) }
        let orientation: Int32
        switch rotation.rawValue {
        case 1: orientation = 6
        case 2: orientation = 3
        case 3: orientation = 8
        default: return nil
        }
        let image = CIImage(cvPixelBuffer: source).oriented(forExifOrientation: orientation)
        var output: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                nil,
                Int(image.extent.width),
                Int(image.extent.height),
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [
                    kCVPixelBufferIOSurfacePropertiesKey: [:],
                    kCVPixelBufferMetalCompatibilityKey: true
                ] as CFDictionary,
                &output
            ) == kCVReturnSuccess, let output
        else { return nil }
        context.render(image, to: output)
        return output
    }
}
