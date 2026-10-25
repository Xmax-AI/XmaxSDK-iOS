//
//  ExternalVideoController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Binds an external video source to local preview and RTC.
final class ExternalVideoController: ExternalVideoControlling, @unchecked Sendable {

    /// The RTC external video adapter.
    private let rtcManager: any RtcManaging

    /// The media sizing service.
    private let mediaService: any MediaServicing

    /// The handler delivering video to transport.
    private let videoFrameListener: MediaVideoFrameListener

    /// The handler delivering external audio to transport without local playback.
    private let audioFrameListener: MediaAudioFrameListener

    /// The handler delivering failures to lifecycle coordination.
    private let errorListener: XmaxErrorListener

    /// The lock protecting cross-thread track access.
    private let lock = NSLock()

    /// The external source's current track.
    private var track: RealtimeVideoTrack?

    /// Whether the current binding owns an external RTC audio track.
    private var storedHasAudio = false

    /// The bound source, with its lifecycle managed on the main actor.
    @MainActor private var source: (any RealtimeExternalVideoSource)?

    /// The synchronous frame sink for this binding.
    @MainActor private var sink: ExternalVideoFrameSink?

    /// The preview presenter.
    @MainActor private var presenter: DecodedVideoPreviewPresenter?

    /// The dispatcher coalescing pending preview frames.
    @MainActor private var dispatcher: DecodedVideoPreviewDispatcher?

    /// Creates an external video lifecycle and preview controller.
    init(
        rtcManager: any RtcManaging,
        mediaService: any MediaServicing,
        videoFrameListener: @escaping MediaVideoFrameListener,
        audioFrameListener: @escaping MediaAudioFrameListener = { _ in
        },
        errorListener: @escaping XmaxErrorListener
    ) {
        self.rtcManager = rtcManager
        self.mediaService = mediaService
        self.videoFrameListener = videoFrameListener
        self.audioFrameListener = audioFrameListener
        self.errorListener = errorListener
    }

    /// The active external video track.
    var currentTrack: RealtimeVideoTrack? {
        lock.withLock {
            track
        }
    }

    /// Whether the current source supplies external audio.
    var hasAudio: Bool {
        lock.withLock {
            storedHasAudio
        }
    }

    /// Binds an external source for preview and generation.
    ///
    /// - Parameter source: The video source owned by your app.
    ///
    /// - Returns: A local stream for SDK video views.
    ///
    /// - Throws: An error if format, RTC configuration, or source binding fails, or the call is
    ///   cancelled.
    @MainActor
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource
    ) async throws -> RealtimeMediaStream {
        guard self.source == nil else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Stop the current external video stream before creating another one"
            )
        }

        let requested = source.videoFormat
        let hasAudio = source.hasAudio
        try requested.validate()
        let size = try mediaService.resolveMediaSize(
            CGSize(
                width: requested.width,
                height: requested.height
            ),
            source: .external
        )
        let format = requested.resized(
            width: Int(size.width),
            height: Int(size.height)
        )
        try format.validate()
        try Task.checkCancellation()

        let track = RealtimeVideoTrack(
            id: "external0",
            videoFormat: format
        )
        let presenter = DecodedVideoPreviewPresenter()
        let dispatcher = DecodedVideoPreviewDispatcher(presenter: presenter)
        let sink = ExternalVideoFrameSink(
            sourceVideoFormat: requested,
            videoFormat: format,
            frameListener: { [videoFrameListener] frame in
                dispatcher.enqueue(frame)
                try videoFrameListener(frame)
            },
            hasAudio: hasAudio,
            audioFrameListener: audioFrameListener,
            errorListener: errorListener
        )

        self.source = source
        self.sink = sink
        self.presenter = presenter
        self.dispatcher = dispatcher
        lock.withLock {
            self.track = track
            storedHasAudio = hasAudio
        }

        do {
            try rtcManager.useExternalVideoSource()
            if hasAudio {
                try rtcManager.startExternalAudioSource()
            }

            VideoRenderRegistry.register(
                track,
                binding: VideoRenderBinding(
                    attachHandler: { view, contentMode in
                        guard let view = view as? XmaxRealtimeVideoView else {
                            throw XmaxError(
                                code: .invalidConfiguration,
                                message: "External video tracks require an XmaxRealtimeVideoView"
                            )
                        }
                        presenter.attach(
                            to: view,
                            contentMode: contentMode
                        )
                    },
                    detachHandler: { view in
                        if let view = view as? XmaxRealtimeVideoView {
                            presenter.detach(from: view)
                        }
                    }
                )
            )

            try await source.start(sink: sink)
            try Task.checkCancellation()
            guard sink.isRequestingFrames else {
                throw XmaxError(
                    code: .mediaError,
                    message: "External video source failed during setup"
                )
            }

            return RealtimeMediaStream(
                id: StreamID.local.rawValue,
                videoTrack: track
            )
        } catch {
            await stopExternalVideoStream()
            throw XmaxError.from(error)
        }
    }

    /// Unbinds the source after invalidating frame delivery and clearing preview.
    @MainActor
    func stopExternalVideoStream() async {
        sink?.invalidate()
        sink = nil
        dispatcher?.reset()
        dispatcher = nil
        presenter?.clear()
        presenter = nil
        let previousSource = source
        source = nil
        let previousState = lock.withLock {
            let previous = track
            let hadAudio = storedHasAudio
            track = nil
            storedHasAudio = false
            return (track: previous, hasAudio: hadAudio)
        }

        if previousState.hasAudio {
            do {
                try rtcManager.stopExternalAudioSource()
            } catch {
                XmaxLogger.media.error(
                    message: """
                        停止 RTC 外部音频源失败 (Failed to Stop RTC External Audio Source)
                        └─ \(XmaxLogger.localized("原因：", "Reason: "))\(error.localizedDescription)
                        """
                )
            }
        }

        if let previousTrack = previousState.track {
            do {
                try VideoRenderRegistry.binding(for: previousTrack)?.detach()
            } catch {
                XmaxLogger.media.error(
                    message:
                        "解除外部视频预览失败 (Failed to Detach External Video Preview)\n└─ \(error.localizedDescription)"
                )
            }
            VideoRenderRegistry.unregister(previousTrack)
        }

        await previousSource?.stop()
    }
}
