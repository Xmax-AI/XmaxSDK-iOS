//
//  XmaxRealtimeConnectionManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A closure that indicates whether a connection operation is still current.
///
/// - Returns: `true` if the operation belongs to the current connection lifecycle.
typealias RealtimeConnectionValidity = @Sendable () -> Bool

/// An asynchronous handler for a session heartbeat failure.
///
/// - Parameters:
///   - sessionID: The identifier of the session whose heartbeat failed.
///   - error: The error reported by the heartbeat request.
typealias RealtimeConnectionHeartbeatFailureHandler =
    @Sendable (
        _ sessionID: String,
        _ error: XmaxError
    ) async -> Void

/// Manages server sessions, RTC connections, and remote media resources.
actor XmaxRealtimeConnectionManager {

    // MARK: - Dependencies

    /// Reports recoverable output-configuration failures.
    private let errorManager: XmaxRealtimeErrorManager

    /// The media component that handles interactions from the remote video view.
    private let interactionController: any InteractionControlling

    /// The controller that manages remote video rendering.
    private let renderController: any RenderControlling

    /// The controller that manages RTC connections and local stream publishing.
    private let streamController: any StreamControlling

    /// The service that creates, maintains, and closes server sessions.
    private let sessionService: any RealtimeSessionServicing

    /// Model sizing and capability rules for transport and remote output.
    private nonisolated let mediaService: any MediaServicing

    /// The recorder for connection startup timings.
    private let timing: RealtimeTiming

    // MARK: - State

    /// The remote video track for the current connection.
    private var activeRemoteTrack: RealtimeVideoTrack?

    /// The server session owned by this connection.
    private var activeSession: RealtimeSession?

    /// Measures session startup with a monotonic clock.
    private var connectionStartedAt: TimeInterval?

    /// Starts HTTP heartbeats once per server session.
    private var heartbeatStarted = false

    /// The callback retained until generation is ready to start the heartbeat loop.
    private var heartbeatFailureHandler: RealtimeConnectionHeartbeatFailureHandler?

    /// The most recently applied target dimensions for server output, in pixels.
    private(set) var currentTargetSize: CGSize?

    /// Creates a connection manager with the specified dependencies.
    init(
        errorManager: XmaxRealtimeErrorManager = XmaxRealtimeErrorManager(),
        interactionController: any InteractionControlling,
        renderController: any RenderControlling,
        streamController: any StreamControlling,
        sessionService: any RealtimeSessionServicing,
        mediaService: any MediaServicing = MediaService(),
        timing: RealtimeTiming = RealtimeTiming()
    ) {
        self.errorManager = errorManager
        self.interactionController = interactionController
        self.renderController = renderController
        self.streamController = streamController
        self.sessionService = sessionService
        self.mediaService = mediaService
        self.timing = timing
    }

    /// The active session identifier, or an empty string if no session is active.
    var currentSessionID: String {
        activeSession?.id ?? ""
    }

    /// The remote media stream for the active session.
    ///
    /// This value is `nil` until both the session and remote video track are available.
    var currentRemoteStream: RealtimeMediaStream? {
        guard activeSession != nil, let activeRemoteTrack else {
            return nil
        }
        return RealtimeMediaStream(
            id: StreamID.remote.rawValue,
            videoTrack: activeRemoteTrack
        )
    }

    /// Updates the remote track's format using the current target dimensions.
    ///
    /// - Parameter videoFormat: The resolved local media format. Its dimensions are replaced by the
    ///   target dimensions, if set.
    func updateRemoteVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async {
        guard let activeRemoteTrack else {
            return
        }
        let remoteFormat = remoteVideoFormat(for: videoFormat)
        activeRemoteTrack.updateVideoFormat(remoteFormat)
    }

    /// The connected session and its assigned model instance, or `nil` while disconnected.
    var currentSession: RealtimeSession? {
        activeSession
    }

    /// Updates target output dimensions and the remote track's format.
    ///
    /// - Parameters:
    ///   - size: The target dimensions of the server's output video, in pixels.
    ///   - videoFormat: The resolved local media format, whose frame rate and encoding options are
    ///     preserved.
    func updateTargetSize(
        _ size: CGSize,
        videoFormat: RealtimeVideoFormat
    ) async {
        guard activeSession != nil else {
            return
        }
        currentTargetSize = size
        await updateRemoteVideoFormat(videoFormat)
    }

    /// Establishes a realtime session and prepares its remote stream.
    ///
    /// The returned stream may not yet have a displayable frame.
    ///
    /// - Parameters:
    ///   - model: The generation model for this session.
    ///   - videoFormat: The resolved local media format used to initialize the interaction
    ///     coordinate space and remote track.
    ///   - targetSize: The server's target output dimensions, or `nil` to use the resolved media
    ///     dimensions.
    ///   - includeLocalAudio: Whether to publish local audio.
    ///   - isCurrent: A closure that indicates whether this connection operation is still current.
    ///   - onHeartbeatFailure: The handler for heartbeat errors from this session.
    ///
    /// - Returns: The remote media stream for the established connection.
    ///
    /// - Throws: An error if session creation, RTC connection, or local publishing fails, or if the
    ///   connection operation is cancelled.
    func connect(
        model: RealtimeModel,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        includeLocalAudio: Bool,
        isCurrent: @escaping RealtimeConnectionValidity,
        onHeartbeatFailure: @escaping RealtimeConnectionHeartbeatFailureHandler
    ) async throws -> RealtimeMediaStream {
        currentTargetSize = targetSize
        var session: RealtimeSession?
        var sessionActivated = false

        do {
            connectionStartedAt = ProcessInfo.processInfo.systemUptime
            heartbeatStarted = false
            heartbeatFailureHandler = onHeartbeatFailure
            timing.beginSessionCreation()
            session = try await sessionService.createSession(model: model)
            timing.finishSessionCreation()
            try Self.ensureCurrent(isCurrent)
            guard let session, let connection = session.connection else {
                throw XmaxError(
                    code: .sessionError,
                    message: "Session does not contain complete RTC join information"
                )
            }

            try await streamController.connect(
                connection: connection,
                includeLocalAudio: includeLocalAudio,
                ensureActive: {
                    try Self.ensureCurrent(isCurrent)
                }
            )
            try Self.ensureCurrent(isCurrent)

            let remoteTrack = RealtimeVideoTrack(
                id: connection.botName ?? "video-remote",
                videoFormat: remoteVideoFormat(for: videoFormat)
            )
            await registerRemoteTrack(
                remoteTrack,
                resolvedMediaSize: videoFormat.size
            )

            activeSession = session
            activeRemoteTrack = remoteTrack
            sessionActivated = true
            try Self.ensureCurrent(isCurrent)

            return RealtimeMediaStream(
                id: StreamID.remote.rawValue,
                videoTrack: remoteTrack
            )
        } catch {
            if isCurrent() {
                await rollbackConnection()
            }

            if let session, !sessionActivated {
                await closeSessionAfterFailedConnection(session.id)
            }
            guard isCurrent() else {
                throw XmaxError(
                    code: .cancelled,
                    message: "Realtime connection was cancelled"
                )
            }
            throw XmaxError.from(error)
        }
    }

    /// Starts the first HTTP heartbeat only after the current session enters generating.
    func startHeartbeat(sessionID: String) {
        guard activeSession?.id == sessionID, !heartbeatStarted,
            let connectionStartedAt, let onFailure = heartbeatFailureHandler
        else { return }
        heartbeatStarted = true
        let elapsed = ProcessInfo.processInfo.systemUptime - connectionStartedAt
        let seconds = max(0, Int(ceil(elapsed)))
        sessionService.startHeartbeat(
            sessionID: sessionID,
            firstHeartbeatGraceSeconds: seconds,
            onFailure: { [weak self] id, error in
                await self?.handleHeartbeatFailure(sessionID: id, error: error, onFailure: onFailure)
            }
        )
    }

    /// Ignores late heartbeat errors after the connection has been replaced or closed.
    private func handleHeartbeatFailure(
        sessionID: String,
        error: XmaxError,
        onFailure: RealtimeConnectionHeartbeatFailureHandler
    ) async {
        guard heartbeatStarted, activeSession?.id == sessionID else { return }
        await onFailure(sessionID, error)
    }

    /// Disconnects RTC, releases remote rendering resources, and closes the server session.
    ///
    /// - Returns: The identifier of the closed session, or `nil` if no session was active.
    ///
    /// - Throws: An error if the server session can't be closed.
    @discardableResult
    func disconnect() async throws -> String? {
        let session = activeSession
        let remoteTrack = activeRemoteTrack
        activeSession = nil
        activeRemoteTrack = nil
        currentTargetSize = nil

        heartbeatStarted = false
        connectionStartedAt = nil
        heartbeatFailureHandler = nil
        sessionService.stopHeartbeat()
        await resetRemoteRendering(track: remoteTrack)
        await streamController.disconnect()

        let sessionID = session?.id
        if let sessionID {
            try await sessionService.closeSession(sessionID: sessionID)
        }
        return sessionID
    }

    /// Prepares the initial encoder and remote dimensions for a connection.
    ///
    /// - Parameters:
    ///   - baseline: The resolved local media format used as the quality baseline.
    ///   - options: The model and adaptive quality settings for this connection.
    ///   - ensureCurrent: The validity check for the current lifecycle operation.
    ///
    /// - Returns: The initial return dimensions, constrained by quality and interpolation limits.
    ///
    /// - Throws: An error if the operation is invalidated or encoding or target-size resolution
    ///   fails.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        options: RealtimeConfiguration,
        ensureCurrent: @Sendable () throws -> Void
    ) async throws -> CGSize? {
        try ensureCurrent()
        let quality = streamController.prepareQuality(
            baseline: baseline,
            model: options.model.rawValue,
            minimumInputPixels: options.model.minimumInputPixels,
            isAdaptiveQualityEnabled: options.isAdaptiveQualityEnabled
        )
        try streamController.setVideoEncoderConfig(quality.uplink)
        let targetSize = try await reconcileFrameInterpolation(
            for: baseline
        )
        try ensureCurrent()
        return targetSize
    }

    /// Records the successfully applied initial quality after generation becomes ready.
    func completeInitialQuality() {
        guard let quality = streamController.qualityConfiguration else {
            return
        }

        streamController.completeQuality(
            downlink: false,
            level: quality.uplinkLevel,
            success: true
        )
        streamController.completeQuality(
            downlink: true,
            level: quality.downlinkLevel,
            success: true
        )
    }

    /// Resolves the returned video format using the quality level and interpolation limits.
    ///
    /// - Parameters:
    ///   - baseline: The resolved local media format.
    ///   - level: The requested downlink quality level.
    ///   - interpolation: Whether to apply the frame interpolation pixel limit.
    ///
    /// - Returns: A format that prioritizes the media aspect ratio within quality and interpolation
    ///   limits, aligned to multiples of 4.
    ///
    /// - Throws: An error if the baseline is invalid or valid output dimensions cannot be resolved.
    nonisolated func resolveTargetVideoFormat(
        baseline: RealtimeVideoFormat,
        level: RealtimeQualityLevel,
        interpolation: Bool
    ) throws -> RealtimeVideoFormat {
        try baseline.validate()

        let maximumSize = QualityVideoFormat.resolveDownlinkMaximumSize(
            baseline,
            level: level
        )
        let targetSize = try mediaService.resolveTargetSize(
            baseline.size,
            maximumSize: maximumSize,
            frameInterpolationEnabled: interpolation
        )
        let format = QualityVideoFormat.resolve(
            baseline,
            level: level,
            downlink: true
        )
        return format.resized(
            width: Int(targetSize.width),
            height: Int(targetSize.height)
        )
    }

    /// Applies a quality level to uplink encoding or downlink output.
    ///
    /// - Parameters:
    ///   - level: The requested quality level.
    ///   - downlink: Whether to change returned dimensions rather than local encoding settings.
    ///   - taskID: The generation task whose transport settings are being updated.
    ///   - ensureCurrent: Validates the admitted operation across asynchronous boundaries.
    ///
    /// - Throws: An error if cancelled, interpolation is unsupported, or signaling or encoder
    ///   configuration fails.
    func applyQualityLevel(
        _ level: RealtimeQualityLevel,
        downlink: Bool,
        taskID: String,
        ensureCurrent: @escaping @Sendable () throws -> Void
    ) async throws {
        guard let configuration = streamController.qualityConfiguration else {
            return
        }

        do {
            try ensureCurrent()
            let format: RealtimeVideoFormat
            if downlink {
                let interpolation = await renderController.isFrameInterpolationEnabled
                try ensureCurrent()
                format = try resolveTargetVideoFormat(
                    baseline: configuration.baseline,
                    level: level,
                    interpolation: interpolation
                )
                guard !interpolation || mediaService.supportsFrameInterpolation(for: format.size)
                else {
                    throw XmaxError(
                        code: .frameInterpolationUnsupported,
                        message: "Frame interpolation is unavailable for the target size"
                    )
                }

                if currentTargetSize != format.size {
                    try ensureCurrent()
                    try await streamController.changeTargetSize(
                        taskID: taskID,
                        targetSize: format.size,
                        ensureActive: {
                            try ensureCurrent()
                        }
                    )

                    // Commit expected dimensions after signaling; disconnection waits for this commit before cleanup.
                    await updateTargetSize(
                        format.size,
                        videoFormat: configuration.baseline
                    )
                    try await renderController.setFrameInterpolationEnabled(
                        interpolation,
                        videoFormat: format
                    )
                }
            } else {
                format = QualityVideoFormat.resolve(
                    configuration.baseline,
                    level: level,
                    downlink: false,
                    minimumInputPixels: configuration.minimumInputPixels
                )
                try streamController.setVideoEncoderConfig(format)
            }

            try ensureCurrent()
            streamController.completeQuality(
                downlink: downlink,
                level: level,
                success: true
            )
            XmaxLogger.realtime.debug(
                message: "传输调档 (Quality Adjustment)\n"
                    + "└─ \(downlink ? "Downlink" : "Uplink"): L\(level.rawValue), \(format.width) × \(format.height)"
            )
        } catch {
            guard (try? ensureCurrent()) != nil else {
                throw error
            }

            streamController.completeQuality(
                downlink: downlink,
                level: level,
                success: false
            )
            XmaxLogger.realtime.warn(
                message:
                    "传输调档失败 (Quality Adjustment Failed)\n└─ \(ErrorMessageFormatter.format(error))"
            )
            throw error
        }
    }

    /// Applies output dimensions and the requested interpolation mode within an admitted operation.
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable remote frame interpolation.
    ///   - mediaFormat: The resolved local media format, if a local stream exists.
    ///   - taskID: The active generation task, or `nil` before generation starts.
    ///   - ensureCurrent: The validity check for the current lifecycle operation.
    ///
    /// - Throws: An error if the operation is invalidated, interpolation is unsupported, or
    ///   signaling or rendering configuration fails.
    func setFrameInterpolationEnabled(
        _ enabled: Bool,
        mediaFormat: RealtimeVideoFormat?,
        taskID: String?,
        ensureCurrent: @escaping @Sendable () throws -> Void
    ) async throws {
        do {
            let targetSize = try mediaFormat.map {
                try resolveTargetVideoFormat(
                    baseline: $0,
                    level: streamController.qualityConfiguration?.downlinkLevel ?? .l2,
                    interpolation: enabled
                ).size
            }
            if enabled, let targetSize,
                !mediaService.supportsFrameInterpolation(for: targetSize)
            {
                throw XmaxError(
                    code: .frameInterpolationUnsupported,
                    message: "Frame interpolation is unavailable for "
                        + "\(Int(targetSize.width)) × \(Int(targetSize.height)) video"
                )
            }

            try ensureCurrent()
            if let taskID, let targetSize,
                currentTargetSize != targetSize
            {
                try await streamController.changeTargetSize(
                    taskID: taskID,
                    targetSize: targetSize,
                    ensureActive: {
                        try ensureCurrent()
                    }
                )
            }

            // Complete the local commit after signaling; concurrent disconnection waits before cleanup.
            if let mediaFormat, let targetSize {
                await updateTargetSize(
                    targetSize,
                    videoFormat: mediaFormat
                )
            }

            var returnFormat = mediaFormat
            if let mediaFormat, let targetSize {
                returnFormat = mediaFormat.resized(
                    width: Int(targetSize.width),
                    height: Int(targetSize.height)
                )
            }

            try await renderController.setFrameInterpolationEnabled(
                enabled,
                videoFormat: returnFormat
            )
        } catch {
            throw XmaxError.from(error)
        }
    }

    /// Configures output dimensions, disabling unsupported interpolation without stopping local
    /// media.
    ///
    /// - Parameter videoFormat: The resolved local media format.
    ///
    /// - Returns: Dimensions constrained by quality and interpolation limits, or `nil` without a
    ///   video format.
    ///
    /// - Throws: An error if valid output dimensions aligned to multiples of 4 cannot be resolved.
    @discardableResult
    func reconcileFrameInterpolation(
        for videoFormat: RealtimeVideoFormat?
    ) async throws -> CGSize? {
        guard let videoFormat else {
            return nil
        }

        let level = streamController.qualityConfiguration?.downlinkLevel ?? .l2
        let fallbackFormat = try resolveTargetVideoFormat(
            baseline: videoFormat,
            level: level,
            interpolation: false
        )
        let interpolation = await renderController.isFrameInterpolationEnabled

        do {
            let targetSize = try resolveTargetVideoFormat(
                baseline: videoFormat,
                level: level,
                interpolation: interpolation
            ).size
            guard !interpolation || mediaService.supportsFrameInterpolation(for: targetSize) else {
                throw XmaxError(
                    code: .frameInterpolationUnsupported,
                    message: "Frame interpolation is unavailable for "
                        + "\(Int(targetSize.width)) × \(Int(targetSize.height)) video"
                )
            }

            try await renderController.setFrameInterpolationEnabled(
                interpolation,
                videoFormat: videoFormat.resized(
                    width: Int(targetSize.width),
                    height: Int(targetSize.height)
                )
            )
            return targetSize
        } catch {
            try? await renderController.setFrameInterpolationEnabled(
                false,
                videoFormat: fallbackFormat
            )
            await errorManager.report(XmaxError.from(error))
            return fallbackFormat.size
        }
    }

}

private extension XmaxRealtimeConnectionManager {

    /// Derives a remote video format by applying the current target dimensions.
    ///
    /// - Parameter mediaFormat: The resolved local media format.
    ///
    /// - Returns: A format with the target dimensions, or the original format if no target
    ///   dimensions are set.
    func remoteVideoFormat(
        for mediaFormat: RealtimeVideoFormat
    ) -> RealtimeVideoFormat {
        guard let currentTargetSize else {
            return mediaFormat
        }
        return mediaFormat.resized(
            width: Int(currentTargetSize.width),
            height: Int(currentTargetSize.height)
        )
    }

    /// Verifies that a connection operation still belongs to the current lifecycle.
    ///
    /// - Parameter isCurrent: The closure that checks the operation's validity.
    ///
    /// - Throws: A cancellation error if the operation is no longer current.
    static func ensureCurrent(
        _ isCurrent: RealtimeConnectionValidity
    ) throws {
        guard isCurrent() else {
            throw XmaxError(
                code: .cancelled,
                message: "Realtime connection was cancelled"
            )
        }
    }

    /// Registers a remote track for rendering and forwards view interactions to the media layer.
    ///
    /// - Parameters:
    ///   - track: The remote video track to register.
    ///   - resolvedMediaSize: The resolved local media dimensions used to map interaction
    ///     coordinates.
    func registerRemoteTrack(
        _ track: RealtimeVideoTrack,
        resolvedMediaSize: CGSize
    ) async {
        let interactionController = interactionController
        await renderController.registerRemoteTrack(
            track,
            resolvedMediaSize: resolvedMediaSize,
            interactionListener: { frame in
                await interactionController.submitInteraction(frame)
            }
        )
    }

    /// Releases resources after a failed connection attempt.
    func rollbackConnection() async {
        let remoteTrack = activeRemoteTrack
        activeSession = nil
        activeRemoteTrack = nil
        currentTargetSize = nil

        heartbeatStarted = false
        connectionStartedAt = nil
        heartbeatFailureHandler = nil
        sessionService.stopHeartbeat()
        await resetRemoteRendering(track: remoteTrack)
        await streamController.disconnect()
    }

    /// Releases remote rendering resources.
    ///
    /// - Parameter track: The remote track to reset, or `nil` to clear rendering state without a
    ///   bound track.
    func resetRemoteRendering(
        track: RealtimeVideoTrack?
    ) async {
        do {
            try await renderController.resetRemoteTrack(track)
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    重置远端视频渲染失败 (Failed to Reset Remote Video Rendering)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }
    }

    /// Closes a session after connection setup fails.
    ///
    /// - Parameter sessionID: The identifier of the session to close.
    func closeSessionAfterFailedConnection(
        _ sessionID: String
    ) async {
        do {
            try await sessionService.closeSession(sessionID: sessionID)
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    连接回滚关闭会话失败 (Failed to Close Session During Connection Rollback)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }
    }
}
