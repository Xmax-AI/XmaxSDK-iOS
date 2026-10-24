//
//  RealtimeExternalVideoSource.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo

/// A video source that supplies frames captured, decoded, or processed by your app.
///
/// XmaxSDK uses the frames for local preview and realtime generation. Your app manages permissions,
/// capture devices, playback, and resource cleanup. A source can also supply PCM audio. XmaxSDK
/// doesn't capture microphone audio or play submitted audio locally.
///
/// Lifecycle methods run on the main actor. You can submit frames from a capture or processing
/// queue.
@MainActor
public protocol RealtimeExternalVideoSource: AnyObject, Sendable {

    /// The source frame dimensions, frame rate, and encoding options.
    ///
    /// Keep this value unchanged until frame delivery stops.
    var videoFormat: RealtimeVideoFormat {
        get
    }

    /// Whether this source supplies audio for RTC upload. The default is `false`.
    ///
    /// Keep this value unchanged until frame delivery stops. Audio and video timestamps must
    /// use the same monotonic timeline.
    var hasAudio: Bool {
        get
    }

    /// Starts delivering video frames to the specified sink.
    ///
    /// Install your frame callback and return when the source is ready to deliver frames. You don't
    /// need to submit the first frame before returning or wait for generation to begin. Continue
    /// delivering frames while disconnected to keep the local preview running.
    ///
    /// Pace frames according to the source's `videoFormat`, with orientation and mirroring applied
    /// to the pixels. If startup fails or is cancelled, XmaxSDK calls `stop()` to end frame
    /// delivery.
    ///
    /// - Parameter sink: The receiver for frames from this source.
    ///
    /// - Throws: An error if the source can't start delivering frames.
    func start(
        sink: any RealtimeExternalFrameSink
    ) async throws

    /// Stops delivering frames and releases the source's reference to the sink.
    ///
    /// This method must be safe to call more than once. Your app retains ownership of its capture
    /// devices and players and decides when to release them.
    func stop() async
}

/// Default audio behavior for external video sources.
public extension RealtimeExternalVideoSource {

    /// Supplies video without audio unless the source opts in.
    var hasAudio: Bool {
        false
    }
}

/// A receiver for video and optional audio from a single source attachment.
///
/// The sink processes frames synchronously and discards further input after delivery stops or the
/// source fails. You can submit frames from any queue.
public protocol RealtimeExternalFrameSink: AnyObject, Sendable {

    /// The processed media format used for local preview and adaptive quality.
    ///
    /// XmaxSDK scales the pixel area into the model's supported range and aligns each dimension to
    /// a multiple of four. The source frame rate and encoding options are preserved. Submit frames
    /// at the source's dimensions; XmaxSDK resizes them to this format.
    var videoFormat: RealtimeVideoFormat {
        get
    }

    /// A Boolean value that indicates whether the sink accepts source frames.
    ///
    /// This value remains `true` while disconnected so frames can drive the local preview. It
    /// becomes `false` when the source is detached or fails.
    var isRequestingFrames: Bool {
        get
    }

    /// Submits a video frame for local preview and realtime generation.
    ///
    /// XmaxSDK copies or resizes the pixels before this method returns. You can reuse the buffer
    /// afterward, but must not modify it during submission. Invalid, duplicate, or decreasing
    /// timestamps are ignored.
    ///
    /// - Parameters:
    ///   - pixelBuffer: An upright NV12 video-range (`420v`) or BGRA buffer whose dimensions match
    ///     the source's `videoFormat`, with any required mirroring already applied.
    ///   - timestamp: A nonnegative, strictly increasing timestamp from a monotonic clock. Keep
    ///     timestamps increasing across seeks and playback loops.
    func pushVideo(
        _ pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    )

    /// Submits PCM audio for RTC upload without local playback.
    ///
    /// Set the source's `hasAudio` to `true` before binding. XmaxSDK copies the samples before
    /// returning and converts them to 48 kHz mono PCM16 in 10 ms packets. The PCM format must
    /// remain unchanged during the binding. Audio submitted without opting in is ignored.
    /// Audio is uploaded only while published and isn't queued for reconnection.
    ///
    /// Buffers must contain contiguous PCM samples and a nonnegative presentation timestamp on
    /// the same monotonic timeline as video. Invalid timestamps and overlapping buffers are
    /// ignored. A gap starts a new audio segment without filling the gap with silence.
    ///
    /// - Parameter sampleBuffer: A ready linear PCM buffer. Its presentation timestamp identifies
    ///   the first sample. Compressed audio must be decoded before submission.
    func pushAudio(
        _ sampleBuffer: CMSampleBuffer
    )

    /// Reports a source failure that prevents further frame delivery.
    ///
    /// XmaxSDK ends the realtime connection and releases the local stream.
    ///
    /// - Parameter error: The unrecoverable capture, decoding, or processing error.
    func reportError(
        _ error: any Error
    )
}
