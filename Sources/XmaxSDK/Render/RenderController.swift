//
//  RenderController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import UIKit

/// Coordinates video tracks, remote frame processing, and trajectory rendering.
@MainActor
final class RenderController: RenderControlling {

    /// A remote first-frame waiter and its timeout.
    private final class RemoteFrameReadyWaiter {

        /// The continuation completing first-frame readiness.
        let continuation: AsyncThrowingStream<Void, any Error>.Continuation

        /// The remote first-frame timeout task.
        var timeoutTask: Task<Void, Never>?

        /// Creates a remote first-frame waiter.
        init(
            continuation:
                AsyncThrowingStream<Void, any Error>.Continuation
        ) {
            self.continuation = continuation
        }
    }

    // MARK: - Dependencies

    /// The RTC remote frame provider.
    private let rtcManager: any RtcManaging

    /// The rendering and interpolation failure handler.
    private let errorListener: XmaxErrorListener

    /// The initial interpolation setting.
    private let initialFrameInterpolationEnabled: Bool

    /// The device and frame-size interpolation capability check.
    private let frameInterpolationSupportChecker:
        RemoteVideoFramePipeline.FrameInterpolationSupportChecker

    /// The remote first-frame timeout, in nanoseconds.
    private let remoteFrameReadyTimeoutNanoseconds: UInt64

    // MARK: - State

    /// The bounded, shared audio/video output queue and sample timeline.
    private let remoteMediaFrameDispatcher = RealtimeMediaFrameDispatcher()

    /// The token rejecting packets from previous result-stream bindings.
    private var remoteMediaStreamID: UUID?

    /// The result stream whose native PCM listener is installed.
    private var activeRemoteAudioStream: RemoteStream?

    /// The current rendering revision.
    private var renderingToken: UInt64 = 0

    /// The remote frame processing and interpolation pipeline.
    private lazy var remoteFramePipeline = RemoteVideoFramePipeline(
        interpolationEnabled: initialFrameInterpolationEnabled,
        outputToken: renderingToken,
        frameInterpolationSupportChecker:
            frameInterpolationSupportChecker,
        outputListener: { [weak self] frame, outputToken in
            await self?.displayRemoteFrame(
                frame,
                outputToken: outputToken
            )
        },
        errorListener: { error in
            XmaxLogger.realtime.error(
                message:
                    "插帧已降级 (Frame Interpolation Disabled)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))\(error.message)"
            )
        }
    )

    /// The remote stream bound for rendering.
    private var remoteStream: RemoteStream?

    /// The remote stream currently producing frames.
    private var activeRemoteFrameStream: RemoteStream?

    /// The attached remote video view.
    private weak var remoteView: XmaxRealtimeVideoView?

    /// The remote video content mode.
    private var remoteContentMode = VideoContentMode.fill

    /// The most recent frame retained for immediate display on attachment.
    private var latestRemoteFrame: RealtimeVideoFrame?

    /// The pending result stream first-frame wait.
    private var remoteFrameReadyWaiters: [UUID: RemoteFrameReadyWaiter] = [:]

    /// Creates a remote rendering and interpolation controller.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC decoded frame provider.
    ///   - frameInterpolationEnabled: Whether interpolation is initially enabled.
    ///   - frameInterpolationSupportChecker: The target-dimension interpolation capability check.
    ///   - remoteFrameReadyTimeoutNanoseconds: The remote first-frame timeout, in nanoseconds.
    ///   - errorListener: The rendering failure handler.
    init(
        rtcManager: any RtcManaging,
        frameInterpolationEnabled: Bool = false,
        frameInterpolationSupportChecker:
            @escaping RemoteVideoFramePipeline
            .FrameInterpolationSupportChecker = {
                FrameInterpolationSupport.supports(size: $0)
            },
        remoteFrameReadyTimeoutNanoseconds: UInt64 = 10_000_000_000,
        errorListener: @escaping XmaxErrorListener = { _ in
        }
    ) {
        self.rtcManager = rtcManager
        initialFrameInterpolationEnabled = frameInterpolationEnabled
        self.frameInterpolationSupportChecker =
            frameInterpolationSupportChecker
        self.remoteFrameReadyTimeoutNanoseconds =
            remoteFrameReadyTimeoutNanoseconds
        self.errorListener = errorListener
    }

    /// Whether remote frame interpolation is enabled.
    var isFrameInterpolationEnabled: Bool {
        get async {
            await remoteFramePipeline.isFrameInterpolationEnabled
        }
    }

    /// Changes the remote source, invalidating cached frames and waits for the previous stream.
    ///
    /// - Parameter stream: The remote stream, or `nil` to clear it.
    ///
    /// - Throws: An error if frame listener removal or attachment fails.
    func setRemoteStream(
        _ stream: RemoteStream?
    ) throws {
        let previousStream = remoteStream
        guard previousStream != stream else {
            try activateRemoteFramesIfReady(reportsError: false)
            if remoteMediaFrameDispatcher.hasListener {
                try activateRemoteAudioIfReady()
            }
            return
        }

        if let previousStream {
            try deactivateRemoteFrames(for: previousStream)
            try deactivateRemoteAudio(for: previousStream)
        }

        remoteStream = stream
        remoteMediaStreamID = remoteMediaFrameDispatcher.setStream(active: stream != nil)
        refreshRenderingToken()
        guard stream != nil else {
            remoteView?.clearDecodedVideoPreview()
            return
        }
        try activateRemoteFramesIfReady(reportsError: false)
        if remoteMediaFrameDispatcher.hasListener {
            try activateRemoteAudioIfReady()
        }
    }

    /// Sets shared media output and attaches PCM only while an application requests it.
    ///
    /// - Parameter listener: The output handler, or `nil` to stop queued output immediately.
    ///
    /// - Throws: An error if the current remote PCM listener cannot be configured.
    func setRemoteMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) throws {
        guard let listener else {
            remoteMediaFrameDispatcher.setListener(nil)
            if let activeRemoteAudioStream {
                try deactivateRemoteAudio(for: activeRemoteAudioStream)
            }
            return
        }
        try activateRemoteAudioIfReady()
        remoteMediaFrameDispatcher.setListener(listener)
    }

    /// Registers remote rendering and trajectory interactions.
    ///
    /// - Parameters:
    ///   - track: The remote video track to register.
    ///   - resolvedMediaSize: The resolved local media dimensions for interaction mapping.
    ///   - interactionListener: The asynchronous view interaction handler.
    func registerRemoteTrack(
        _ track: RealtimeVideoTrack,
        resolvedMediaSize: CGSize,
        interactionListener: @escaping RenderInteractionListener
    ) {
        VideoRenderRegistry.register(
            track,
            binding: VideoRenderBinding(
                attachHandler: { [weak self] view, contentMode in
                    try self?.attachRemoteVideo(
                        to: view,
                        contentMode: contentMode
                    )
                },
                detachHandler: { [weak self] _ in
                    try self?.detachRemoteVideo()
                }
            )
        )

        TrajectoryRegistry.register(
            track,
            binding: TrajectoryBinding(
                interactionListener: interactionListener,
                resolvedMediaSize: resolvedMediaSize
            )
        )
    }

    /// Enables or disables remote frame interpolation.
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable interpolation.
    ///   - videoFormat: The expected returned format, or `nil` before local media creation.
    ///
    /// - Throws: An error if explicitly enabling unsupported interpolation.
    func setFrameInterpolationEnabled(
        _ enabled: Bool,
        videoFormat: RealtimeVideoFormat?
    ) async throws {
        try await remoteFramePipeline.setFrameInterpolationEnabled(
            enabled,
            videoSize: videoFormat.map {
                CGSize(
                    width: $0.width,
                    height: $0.height
                )
            },
            outputToken: renderingToken
        )
    }

    /// Waits for the first processed remote frame ready for display.
    ///
    /// - Throws: An error if cancelled, the remote stream is reset, or the wait times out.
    func waitUntilRemoteFrameReady() async throws {
        guard !Task.isCancelled else {
            throw Self.remoteFrameWaitCancelledError()
        }
        guard remoteStream != nil else {
            throw XmaxError(
                code: .rtcError,
                message: "Remote video stream is unavailable"
            )
        }

        if latestRemoteFrame != nil {
            return
        }

        let waiterID = UUID()
        let activeToken = renderingToken
        var continuation: AsyncThrowingStream<Void, any Error>.Continuation?
        let stream = AsyncThrowingStream<Void, any Error> {
            continuation = $0
        }
        guard let continuation else {
            throw XmaxError(
                code: .internalError,
                message: "Failed to create remote first frame waiter"
            )
        }

        let waiter = RemoteFrameReadyWaiter(continuation: continuation)
        remoteFrameReadyWaiters[waiterID] = waiter

        waiter.timeoutTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(
                    nanoseconds: remoteFrameReadyTimeoutNanoseconds
                )
            } catch {
                return
            }

            finishRemoteFrameReadyWaiter(
                waiterID,
                error: XmaxError(
                    code: .timeout,
                    message: "Remote video first frame timed out"
                )
            )
        }

        try await withTaskCancellationHandler {
            guard activeToken == renderingToken, remoteStream != nil else {
                finishRemoteFrameReadyWaiter(
                    waiterID,
                    error: Self.remoteFrameWaitCancelledError()
                )
                throw Self.remoteFrameWaitCancelledError()
            }

            if latestRemoteFrame != nil {
                finishRemoteFrameReadyWaiter(waiterID)
            }

            for try await _ in stream {
                return
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishRemoteFrameReadyWaiter(
                    waiterID,
                    error: Self.remoteFrameWaitCancelledError()
                )
            }
        }
    }

    /// Unregisters remote rendering and waits for in-flight processing.
    ///
    /// - Parameter track: The track to unregister, or `nil` to clear processing without a track.
    ///
    /// - Throws: An error if RTC frame listener removal fails.
    func resetRemoteTrack(
        _ track: RealtimeVideoTrack?
    ) async throws {
        if let track {
            VideoRenderRegistry.unregister(track)
            TrajectoryRegistry.unregister(track)
        }
        let result = Result {
            try resetRemoteVideo()
        }
        await remoteFramePipeline.reset(outputToken: renderingToken)
        try result.get()
    }
}

private extension RenderController {

    /// Attaches a remote video view and submits a cached valid frame.
    ///
    /// - Parameters:
    ///   - view: The `XmaxRealtimeVideoView` displaying remote video.
    ///   - contentMode: The remote video content mode.
    ///
    /// - Throws: An error if the view type is invalid or remote frame listening fails.
    func attachRemoteVideo(
        to view: UIView,
        contentMode: VideoContentMode
    ) throws {
        guard let videoView = view as? XmaxRealtimeVideoView else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Remote tracks require an XmaxRealtimeVideoView"
            )
        }
        if let remoteView, remoteView !== videoView,
            remoteStream != nil
        {
            remoteView.clearDecodedVideoPreview()
        }

        remoteView = videoView
        remoteContentMode = contentMode
        videoView.prepareDecodedVideoPreview(contentMode: contentMode)
        if let latestRemoteFrame {
            videoView.displayRemoteVideoFrame(
                latestRemoteFrame,
                contentMode: contentMode
            )
        }
        try activateRemoteFramesIfReady(reportsError: true)
    }

    /// Clears the remote picture and detaches the view.
    func detachRemoteVideo() throws {
        remoteView?.clearDecodedVideoPreview()
        self.remoteView = nil
    }

    /// Clears remote frame listening, display, cached frames, and pending waits.
    ///
    /// - Throws: An error if the RTC frame listener cannot be removed.
    func resetRemoteVideo() throws {
        let stream = remoteStream
        remoteStream = nil
        remoteMediaStreamID = remoteMediaFrameDispatcher.setStream(active: false)
        remoteContentMode = .fill

        defer {
            activeRemoteFrameStream = nil
            activeRemoteAudioStream = nil
            remoteView?.clearDecodedVideoPreview()
            remoteView = nil
            refreshRenderingToken()
        }

        if let stream {
            var failure: (any Error)?
            do {
                try deactivateRemoteFrames(for: stream)
            } catch {
                failure = error
            }

            do {
                try deactivateRemoteAudio(for: stream)
            } catch {
                failure = failure ?? error
            }

            if let failure {
                throw failure
            }
        }
    }

    /// Attaches PCM without hopping each native audio callback through the main actor.
    ///
    /// - Throws: An error if the current result user's PCM listener cannot be attached.
    func activateRemoteAudioIfReady() throws {
        guard let remoteStream,
            let streamID = remoteMediaStreamID,
            activeRemoteAudioStream != remoteStream
        else {
            return
        }

        let dispatcher = remoteMediaFrameDispatcher
        try rtcManager.setRemoteAudioFrameListener(
            { frame in
                dispatcher.dispatchAudio(
                    frame,
                    streamID: streamID
                )
            },
            for: remoteStream
        )
        activeRemoteAudioStream = remoteStream
    }

    /// Removes one binding's PCM listener; stale captured callbacks remain token-guarded.
    ///
    /// - Parameter stream: The remote stream whose audio callback should be removed.
    ///
    /// - Throws: An error if the RTC audio callback cannot be removed.
    func deactivateRemoteAudio(
        for stream: RemoteStream
    ) throws {
        guard activeRemoteAudioStream == stream else {
            return
        }

        defer {
            activeRemoteAudioStream = nil
        }
        try rtcManager.setRemoteAudioFrameListener(
            nil,
            for: stream
        )
    }

    /// Installs a decoded frame listener for the current remote stream.
    ///
    /// - Parameter reportsError: Whether binding failure also triggers the error handler.
    ///
    /// - Throws: An error if RTC frame listener configuration fails.
    func activateRemoteFramesIfReady(
        reportsError: Bool
    ) throws {
        guard let remoteStream else {
            return
        }
        guard activeRemoteFrameStream != remoteStream else {
            return
        }

        let outputToken = renderingToken

        do {
            try rtcManager.setRemoteVideoFrameListener(
                { [weak remoteFramePipeline] frame in
                    Task {
                        await remoteFramePipeline?.enqueue(
                            frame,
                            outputToken: outputToken
                        )
                    }
                },
                for: remoteStream
            )
            activeRemoteFrameStream = remoteStream
        } catch {
            if reportsError {
                errorListener(XmaxError.from(error))
            }
            throw error
        }
    }

    /// Removes a matching stream's decoded frame listener.
    ///
    /// - Parameter stream: The remote stream to stop observing.
    ///
    /// - Throws: An error if the RTC frame listener cannot be removed.
    func deactivateRemoteFrames(
        for stream: RemoteStream
    ) throws {
        guard activeRemoteFrameStream == stream else {
            return
        }
        try rtcManager.setRemoteVideoFrameListener(
            nil,
            for: stream
        )
        activeRemoteFrameStream = nil
    }

    /// Invalidates previous frames and first-frame waits.
    func refreshRenderingToken() {
        finishAllRemoteFrameReadyWaiters(
            error: Self.remoteFrameWaitCancelledError()
        )
        latestRemoteFrame = nil
        renderingToken &+= 1
        let token = renderingToken
        Task { [remoteFramePipeline] in
            await remoteFramePipeline.reset(outputToken: token)
        }
    }

    /// Caches and dispatches a current processed frame and signals readiness.
    ///
    /// - Parameters:
    ///   - frame: The processed remote video frame.
    ///   - outputToken: The frame's rendering revision.
    func displayRemoteFrame(
        _ frame: RealtimeVideoFrame,
        outputToken: UInt64
    ) {
        guard outputToken == renderingToken else {
            return
        }

        latestRemoteFrame = frame
        finishAllRemoteFrameReadyWaiters()

        if let remoteMediaStreamID {
            remoteMediaFrameDispatcher.dispatchVideo(
                frame,
                streamID: remoteMediaStreamID
            )
        }

        if let remoteView {
            remoteView.displayRemoteVideoFrame(
                frame,
                contentMode: remoteContentMode
            )
        }
    }

    /// Completes a first-frame wait and cancels its timeout.
    ///
    /// - Parameters:
    ///   - waiterID: The waiter identifier.
    ///   - error: The failure, or `nil` if a frame is ready.
    func finishRemoteFrameReadyWaiter(
        _ waiterID: UUID,
        error: XmaxError? = nil
    ) {
        guard
            let waiter = remoteFrameReadyWaiters.removeValue(
                forKey: waiterID
            )
        else {
            return
        }

        waiter.timeoutTask?.cancel()

        if let error {
            waiter.continuation.finish(throwing: error)
        } else {
            waiter.continuation.yield()
            waiter.continuation.finish()
        }
    }

    /// Completes all pending first-frame waits.
    ///
    /// - Parameter error: The failure, or `nil` if a frame is ready.
    func finishAllRemoteFrameReadyWaiters(
        error: XmaxError? = nil
    ) {
        let waiterIDs = Array(remoteFrameReadyWaiters.keys)
        for waiterID in waiterIDs {
            finishRemoteFrameReadyWaiter(
                waiterID,
                error: error
            )
        }
    }

    /// Creates a remote first-frame cancellation error.
    ///
    /// - Returns: An SDK first-frame cancellation error.
    static func remoteFrameWaitCancelledError() -> XmaxError {
        XmaxError(
            code: .cancelled,
            message: "Remote video first frame wait was cancelled"
        )
    }
}
