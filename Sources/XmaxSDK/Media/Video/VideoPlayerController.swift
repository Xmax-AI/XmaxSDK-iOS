//
//  VideoPlayerController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UIKit

/// An interface for file audio and video on a shared timeline.
protocol VideoPlayerControlling: Sendable {

    /// The local audio preview volume.
    @MainActor
    var localAudioVolume: Float {
        get
    }

    /// Configures a local video file and its RTC output format.
    ///
    /// - Parameters:
    ///   - fileURL: The video file URL whose metadata has been read.
    ///   - metadata: The source orientation, duration, and audio information.
    ///   - videoFormat: The resolved output dimensions and frame rate.
    ///
    /// - Throws: An error if the file, output format, or playback state is invalid.
    @MainActor
    func configure(
        fileURL: URL,
        metadata: MediaFileMetadata,
        videoFormat: RealtimeVideoFormat
    ) throws

    /// Starts preview and frame delivery on a shared timeline.
    ///
    /// - Throws: An error if playback is unconfigured or already running.
    @MainActor
    func start() async throws

    /// Mutes or restores audio preview without changing frame output.
    ///
    /// - Parameter muted: Whether to mute local audio.
    @MainActor
    func setLocalAudioPreviewMuted(
        _ muted: Bool
    )

    /// Sets local audio preview volume.
    ///
    /// - Parameter volume: The validated preview volume, in the range `0...1`.
    @MainActor
    func setLocalAudioVolume(
        _ volume: Float
    )

    /// Attaches decoded preview to an SDK video view.
    ///
    /// - Parameters:
    ///   - view: The `XmaxRealtimeVideoView` receiving preview.
    ///   - contentMode: The video content mode.
    ///
    /// - Throws: An error if the view is not an `XmaxRealtimeVideoView`.
    @MainActor
    func attachPreview(
        to view: UIView,
        contentMode: VideoContentMode
    ) throws

    /// Detaches decoded preview from an SDK video view.
    ///
    /// - Parameter view: The view to detach.
    @MainActor
    func detachPreview(
        from view: UIView
    )

    /// Stops decoding and waits for readers to exit in their owning tasks.
    @MainActor
    func stop() async
}

/// An AVAssetReader player with a shared audio and video timeline.
@MainActor
final class VideoPlayerController: VideoPlayerControlling {

    /// The file decoding and playback configuration.
    private struct PlaybackConfiguration: Sendable {

        /// The local video file URL.
        let fileURL: URL

        /// The source orientation, duration, and audio information.
        let metadata: MediaFileMetadata

        /// The resolved dimensions and frame rate for decoded output.
        let videoFormat: RealtimeVideoFormat
    }

    /// The video frame handler.
    private let videoFrameListener: MediaVideoFrameListener

    /// The audio frame handler using the shared playback clock.
    private let audioFrameListener: MediaAudioFrameListener

    /// The video decoding and playback failure handler.
    private let errorListener: XmaxErrorListener

    /// The PCM audio preview on the shared timeline.
    private let audioPreviewPlayer = LocalAudioPreviewPlayer()

    /// The decoded video preview presenter.
    private let previewPresenter = DecodedVideoPreviewPresenter()

    /// The dispatcher coalescing frames for the main actor.
    private lazy var previewDispatcher = DecodedVideoPreviewDispatcher(
        presenter: previewPresenter
    )

    /// The file decoding and output configuration.
    private var configuration: PlaybackConfiguration?

    /// The looping decode and frame scheduling task.
    private var playbackTask: Task<Void, Never>?

    /// Creates a shared-timeline video decoder and audio preview player.
    init(
        videoFrameListener: @escaping MediaVideoFrameListener,
        audioFrameListener: @escaping MediaAudioFrameListener,
        errorListener: @escaping XmaxErrorListener
    ) {
        self.videoFrameListener = videoFrameListener
        self.audioFrameListener = audioFrameListener
        self.errorListener = errorListener
    }

    /// The local preview volume, from 0 to 1.
    var localAudioVolume: Float {
        audioPreviewPlayer.currentVolume
    }

    /// Configures a local video file and its RTC output format.
    ///
    /// - Parameters:
    ///   - fileURL: The video file URL whose metadata has been read.
    ///   - metadata: The source orientation, duration, and audio information.
    ///   - videoFormat: The resolved output dimensions and frame rate.
    ///
    /// - Throws: An error if the file, output format, or playback state is invalid.
    func configure(
        fileURL: URL,
        metadata: MediaFileMetadata,
        videoFormat: RealtimeVideoFormat
    ) throws {
        guard fileURL.isFileURL,
            FileManager.default.fileExists(atPath: fileURL.path),
            videoFormat.width > 0,
            videoFormat.height > 0,
            videoFormat.width.isMultiple(of: 2),
            videoFormat.height.isMultiple(of: 2),
            videoFormat.fps > 0,
            configuration == nil,
            playbackTask == nil
        else {
            throw Self.mediaError("Video player configuration is invalid")
        }

        guard metadata.durationSeconds.isFinite, metadata.durationSeconds > 0 else {
            throw Self.mediaError("The media file has an invalid duration")
        }

        configuration = PlaybackConfiguration(
            fileURL: fileURL,
            metadata: metadata,
            videoFormat: videoFormat
        )
    }

    /// Starts preview and frame delivery on a shared timeline.
    ///
    /// - Throws: An error if playback is unconfigured or already running.
    func start() async throws {
        guard let configuration, playbackTask == nil else {
            throw Self.mediaError("Configure the video player before starting it")
        }

        if configuration.metadata.hasAudio {
            audioPreviewPlayer.start()
            audioPreviewPlayer.setMuted(false)
        }

        let timeline = MediaPlaybackTimeline(
            mediaDurationSeconds: configuration.metadata.durationSeconds
        )
        let videoListener = videoFrameListener
        let audioListener = audioFrameListener
        let errorListener = errorListener
        let audioPreviewPlayer = audioPreviewPlayer
        let previewDispatcher = previewDispatcher

        playbackTask = Task.detached(priority: .userInitiated) {
            do {
                try await Self.play(
                    configuration: configuration,
                    timeline: timeline,
                    videoHandler: { frame in
                        previewDispatcher.enqueue(frame)
                        do {
                            try videoListener(frame)
                        } catch {
                            XmaxLogger.media.error(
                                message:
                                    "视频帧推送失败 (Video Frame Push Failed)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))\(error.localizedDescription)"
                            )
                        }
                    },
                    audioHandler: { frame in
                        audioPreviewPlayer.enqueue(frame)
                        do {
                            try audioListener(frame)
                        } catch {
                            XmaxLogger.media.error(
                                message:
                                    "音频帧推送失败 (Audio Frame Push Failed)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))\(error.localizedDescription)"
                            )
                        }
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                errorListener(XmaxError.from(error))
            }
        }
    }

    /// Mutes or restores audio preview without changing frame output.
    ///
    /// - Parameter muted: Whether to mute local audio.
    func setLocalAudioPreviewMuted(
        _ muted: Bool
    ) {
        audioPreviewPlayer.setMuted(muted)
    }

    /// Sets local audio preview volume.
    ///
    /// - Parameter volume: The validated preview volume, in the range `0...1`.
    func setLocalAudioVolume(
        _ volume: Float
    ) {
        audioPreviewPlayer.setVolume(volume)
    }

    /// Attaches decoded preview to an SDK video view.
    ///
    /// - Parameters:
    ///   - view: The `XmaxRealtimeVideoView` receiving preview.
    ///   - contentMode: The video content mode.
    ///
    /// - Throws: An error if the view is not an `XmaxRealtimeVideoView`.
    func attachPreview(
        to view: UIView,
        contentMode: VideoContentMode
    ) throws {
        guard let videoView = view as? XmaxRealtimeVideoView else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "File video tracks require an XmaxRealtimeVideoView"
            )
        }
        previewPresenter.attach(
            to: videoView,
            contentMode: contentMode
        )
    }

    /// Detaches decoded preview from an SDK video view.
    ///
    /// - Parameter view: The view to detach.
    func detachPreview(
        from view: UIView
    ) {
        guard let videoView = view as? XmaxRealtimeVideoView else {
            return
        }
        previewPresenter.detach(from: videoView)
    }

    /// Stops decoding and waits for readers to exit in their owning tasks.
    func stop() async {
        let task = playbackTask
        playbackTask = nil
        task?.cancel()
        await task?.value
        await audioPreviewPlayer.stop()
        previewDispatcher.reset()
        previewPresenter.clear()
        configuration = nil
    }
}

private extension VideoPlayerController {

    /// The synchronous video frame handler.
    typealias VideoHandler = @Sendable (VideoFrame) throws -> Void

    /// The synchronous fixed-size PCM frame handler.
    typealias AudioHandler = @Sendable (AudioFrame) throws -> Void

    /// Runs audio and video decoding on the same host clock.
    ///
    /// - Parameters:
    ///   - configuration: The file and output configuration.
    ///   - timeline: The shared looping playback timeline.
    ///   - videoHandler: The scheduled video frame handler.
    ///   - audioHandler: The scheduled audio frame handler.
    ///
    /// - Throws: An error if media reading, decoding, or delivery fails, or the task is cancelled.
    private nonisolated static func play(
        configuration: PlaybackConfiguration,
        timeline: MediaPlaybackTimeline,
        videoHandler: @escaping VideoHandler,
        audioHandler: @escaping AudioHandler
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await produceVideoFrames(
                    configuration: configuration,
                    timeline: timeline,
                    handler: videoHandler
                )
            }

            if configuration.metadata.hasAudio {
                group.addTask {
                    try await produceAudioFrames(
                        configuration: configuration,
                        timeline: timeline,
                        handler: audioHandler
                    )
                }
            }

            try await group.waitForAll()
        }
    }

    /// Loops video decoding and schedules resolved frames on the shared timeline.
    ///
    /// - Parameters:
    ///   - configuration: The video file, output dimensions, and sampling frame rate.
    ///   - timeline: The shared playback timeline.
    ///   - handler: The scheduled video frame handler.
    ///
    /// - Throws: An error if video is unavailable, decoding yields no valid frames, delivery fails,
    ///   or the task is cancelled.
    private nonisolated static func produceVideoFrames(
        configuration: PlaybackConfiguration,
        timeline: MediaPlaybackTimeline,
        handler: @escaping VideoHandler
    ) async throws {
        let frameIntervalSeconds = 1 / Double(configuration.videoFormat.fps)
        let frameIntervalNanoseconds = UInt64(
            frameIntervalSeconds * 1_000_000_000
        )
        var loopIndex = 0

        while true {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: configuration.fileURL)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw mediaError("The media file does not contain a video track")
            }

            let timeRange = try await track.load(.timeRange)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw mediaError("The media video track cannot be decoded")
            }

            reader.add(output)
            guard reader.startReading() else {
                throw mediaError(
                    reader.error?.localizedDescription
                        ?? "The media video track could not start decoding"
                )
            }
            defer {
                if reader.status == .reading {
                    reader.cancelReading()
                }
            }

            var yieldedFrame = false
            var lastYieldedSeconds = -Double.infinity

            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    break
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let relativeTime = CMTimeSubtract(
                    pts,
                    timeRange.start
                )
                let relativeSeconds = max(
                    0,
                    CMTimeGetSeconds(relativeTime)
                )
                guard relativeSeconds.isFinite,
                    relativeSeconds - lastYieldedSeconds >= frameIntervalSeconds * 0.75,
                    let pixelBuffer = CMSampleBufferGetImageBuffer(
                        sampleBuffer
                    )
                else {
                    continue
                }

                let target = timeline.target(
                    loopIndex: loopIndex,
                    mediaOffsetSeconds: relativeSeconds
                )
                let now = DispatchTime.now().uptimeNanoseconds
                if now > target, now - target > frameIntervalNanoseconds {
                    continue
                }

                let frame: VideoFrame
                do {
                    frame = try VideoFrameConverter.convert(
                        pixelBuffer: pixelBuffer,
                        outputWidth: configuration.videoFormat.width,
                        outputHeight: configuration.videoFormat.height,
                        rotation: configuration.metadata.rotation,
                        timestampUs: Int64(target / 1_000)
                    )
                } catch {
                    XmaxLogger.media.error(
                        message:
                            "视频帧转换失败 (Video Frame Conversion Failed)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))\(error.localizedDescription)"
                    )
                    continue
                }

                try await sleep(untilNanoseconds: target)
                try handler(frame)
                yieldedFrame = true
                lastYieldedSeconds = relativeSeconds
            }

            if reader.status == .failed {
                throw mediaError(
                    reader.error?.localizedDescription
                        ?? "The media video track failed while decoding"
                )
            }

            guard yieldedFrame else {
                throw mediaError("The media file produced no video frames")
            }

            loopIndex += 1
            let nextLoop = timeline.target(
                loopIndex: loopIndex,
                mediaOffsetSeconds: 0
            )
            try await sleep(untilNanoseconds: nextLoop)
        }
    }

    /// Loops PCM decoding and pads each playback cycle.
    ///
    /// - Parameters:
    ///   - configuration: The video file and audio configuration.
    ///   - timeline: The shared playback timeline.
    ///   - handler: The fixed-size audio frame handler.
    ///
    /// - Throws: An error if audio is unavailable, decoding or delivery fails, or the task is
    ///   cancelled.
    private nonisolated static func produceAudioFrames(
        configuration: PlaybackConfiguration,
        timeline: MediaPlaybackTimeline,
        handler: @escaping AudioHandler
    ) async throws {
        var loopIndex = 0

        while true {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: configuration.fileURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw mediaError("The media file does not contain an audio track")
            }

            let timeRange = try await track.load(.timeRange)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: [track],
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: AudioFrame.sampleRate,
                    AVNumberOfChannelsKey: AudioFrame.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw mediaError("The media audio track cannot be decoded")
            }

            reader.add(output)
            guard reader.startReading() else {
                throw mediaError(
                    reader.error?.localizedDescription
                        ?? "The media audio track could not start decoding"
                )
            }
            defer {
                if reader.status == .reading {
                    reader.cancelReading()
                }
            }

            var packetizer = PCMFramePacketizer(
                totalSamples: timeline.cycleSampleCount
            )

            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    break
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let relativeTime = CMTimeSubtract(
                    pts,
                    timeRange.start
                )
                let relativeSeconds = max(
                    0,
                    CMTimeGetSeconds(relativeTime)
                )
                guard relativeSeconds.isFinite else {
                    continue
                }

                let startSample = Int(
                    (relativeSeconds * Double(AudioFrame.sampleRate)).rounded()
                )
                packetizer.append(
                    try pcmData(from: sampleBuffer),
                    at: startSample
                )
                try await emitAudioFrames(
                    packetizer: &packetizer,
                    loopIndex: loopIndex,
                    timeline: timeline,
                    handler: handler
                )
            }

            if reader.status == .failed {
                throw mediaError(
                    reader.error?.localizedDescription
                        ?? "The media audio track failed while decoding"
                )
            }

            packetizer.finishWithSilence()
            try await emitAudioFrames(
                packetizer: &packetizer,
                loopIndex: loopIndex,
                timeline: timeline,
                handler: handler
            )
            loopIndex += 1
        }
    }

    /// Schedules audio packets, dropping packets beyond the latency limit.
    ///
    /// - Parameters:
    ///   - packetizer: The PCM packetizer.
    ///   - loopIndex: The zero-based playback cycle.
    ///   - timeline: The shared audio and video timeline.
    ///   - handler: The handler for host-timestamped audio frames.
    ///
    /// - Throws: An error if waiting is cancelled or audio delivery fails.
    nonisolated static func emitAudioFrames(
        packetizer: inout PCMFramePacketizer,
        loopIndex: Int,
        timeline: MediaPlaybackTimeline,
        handler: @escaping AudioHandler
    ) async throws {
        while let packet = packetizer.nextFrame() {
            let target = timeline.target(
                loopIndex: loopIndex,
                sampleOffset: packet.sampleOffset
            )
            let now = DispatchTime.now().uptimeNanoseconds
            if now < target {
                try await sleep(untilNanoseconds: target)
            } else if now - target > 30_000_000 {
                continue
            }

            try handler(
                AudioFrame(
                    data: packet.data,
                    timestampUs: Int64(target / 1_000)
                )
            )
        }
    }

    /// Copies PCM data from an audio sample buffer.
    ///
    /// - Parameter sampleBuffer: The decoded audio sample buffer.
    ///
    /// - Returns: The copied PCM, or empty data if no data buffer exists.
    ///
    /// - Throws: An error if PCM bytes cannot be read.
    nonisolated static func pcmData(
        from sampleBuffer: CMSampleBuffer
    ) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return Data()
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw mediaError("The decoded PCM data could not be read")
        }

        return data
    }

    /// Waits until a monotonic host time.
    ///
    /// - Parameter target: The target host time, in nanoseconds.
    ///
    /// - Throws: A cancellation error if waiting is cancelled.
    nonisolated static func sleep(
        untilNanoseconds target: UInt64
    ) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < target else {
            return
        }
        try await Task.sleep(nanoseconds: target - now)
    }

    /// Creates a file playback error.
    ///
    /// - Parameter message: The error description.
    ///
    /// - Returns: A media error with the specified description.
    nonisolated static func mediaError(
        _ message: String
    ) -> XmaxError {
        XmaxError(
            code: .mediaError,
            message: message
        )
    }
}
