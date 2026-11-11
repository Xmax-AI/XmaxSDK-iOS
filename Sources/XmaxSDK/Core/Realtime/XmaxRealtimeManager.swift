//
//  XmaxRealtimeManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Implements the public realtime API and sequences media, connection, and generation workflows.
actor XmaxRealtimeManager: XmaxRealtimeManaging {

    /// The model, interpolation, and adaptive quality configuration supplied at creation.
    nonisolated let options: RealtimeConfiguration

    // MARK: - Dependencies

    /// The lifecycle owner that admits operations and merges termination requests.
    private let lifecycleManager: XmaxRealtimeLifecycleManager

    /// The manager that owns the server session and RTC connection.
    private let connectionManager: XmaxRealtimeConnectionManager

    /// The manager that sends generation requests and confirms result streams.
    private let generationManager: XmaxRealtimeGenerationManager

    /// The manager that logs and forwards media and connection failures.
    private let errorManager: XmaxRealtimeErrorManager

    /// The controller that manages local media, preview, and interactions.
    private let mediaController: any MediaControlling

    /// The controller that manages remote tracks, first-frame readiness, and rendering.
    private let renderController: any RenderControlling

    /// The controller that manages RTC connections, signaling, and transport quality.
    private let streamController: any StreamControlling

    /// The service that resolves media dimensions and model input constraints.
    private let mediaService: any MediaServicing

    /// The recorder for generation startup stage durations.
    private let timing: RealtimeTiming

    // MARK: - Initialization

    /// Creates a realtime manager using the default SDK components.
    @MainActor
    init(
        options: RealtimeConfiguration,
        apiService: any ApiServicing
    ) {
        self.init(
            options: options,
            components: XmaxRealtimeFactory.make(
                options: options,
                apiService: apiService
            )
        )
    }

    /// Creates a realtime manager with the supplied components.
    init(
        options: RealtimeConfiguration,
        components: XmaxRealtimeComponents
    ) {
        self.options = options
        self.lifecycleManager = components.lifecycleManager
        self.connectionManager = components.connectionManager
        self.generationManager = components.generationManager
        self.errorManager = components.errorManager
        self.mediaController = components.mediaController
        self.renderController = components.renderController
        self.streamController = components.streamController
        self.mediaService = components.mediaService
        self.timing = components.timing
    }

    /// Creates a realtime manager with shared lifecycle management for the supplied components.
    init(
        options: RealtimeConfiguration,
        streamController: any StreamControlling,
        mediaController: any MediaControlling,
        renderController: any RenderControlling,
        mediaService: any MediaServicing = MediaService(),
        connectionManager: XmaxRealtimeConnectionManager,
        errorManager: XmaxRealtimeErrorManager,
        generationManager: XmaxRealtimeGenerationManager,
        timing: RealtimeTiming = RealtimeTiming()
    ) {
        self.init(
            options: options,
            components: XmaxRealtimeFactory.assemble(
                connectionManager: connectionManager,
                generationManager: generationManager,
                errorManager: errorManager,
                mediaController: mediaController,
                renderController: renderController,
                streamController: streamController,
                mediaService: mediaService,
                timing: timing
            )
        )
    }

    // MARK: - State

    /// Whether an adaptive quality request is already pending.
    private var qualityPending = false

    /// The current connection and generation state.
    var currentState: RealtimeState {
        get async {
            await lifecycleManager.currentState
        }
    }

    /// The uplink level successfully applied to the current connection.
    var uplinkQualityLevel: RealtimeQualityLevel? {
        get async {
            let state = await lifecycleManager.currentState.connectionState
            guard state == .connected || state == .generating else {
                return nil
            }

            return streamController.qualityConfiguration?.uplinkLevel
        }
    }

    /// The downlink level successfully submitted for the current connection.
    var downlinkQualityLevel: RealtimeQualityLevel? {
        get async {
            let state = await lifecycleManager.currentState.connectionState
            guard state == .connected || state == .generating else {
                return nil
            }

            return streamController.qualityConfiguration?.downlinkLevel
        }
    }

    /// The camera's resolved media format, or `nil` for other input sources.
    var currentCameraVideoFormat: RealtimeVideoFormat? {
        get async {
            guard let track = await mediaController.currentTrack, track.position != nil else {
                return nil
            }

            return track.videoFormat
        }
    }

    /// The preset matching current camera dimensions, independent of frame rate or encoding level.
    var currentCameraPreset: RealtimeCameraPreset? {
        get async {
            guard let format = await currentCameraVideoFormat else {
                return nil
            }

            return RealtimeCameraPreset.allCases.first {
                $0.size == format.size
            }
        }
    }

    /// Whether remote frame interpolation is currently enabled.
    var isFrameInterpolationEnabled: Bool {
        get async {
            await renderController.isFrameInterpolationEnabled
        }
    }

    /// The local preview volume, in the range `0...1`.
    var localAudioVolume: Float {
        get async {
            await mediaController.localAudioVolume
        }
    }

    /// The remote generated audio volume, in the range `0...1`.
    var remoteAudioVolume: Float {
        streamController.remoteAudioVolume
    }

    // MARK: - Quality

    /// Changes the uplink encoding level while allowing subsequent automatic adaptation.
    ///
    /// - Parameter level: The requested uplink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   encoder configuration fails.
    func setUplinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws {
        try await setQualityLevel(
            level,
            downlink: false
        )
    }

    /// Changes the downlink output level while allowing subsequent automatic adaptation.
    ///
    /// - Parameter level: The requested downlink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   signaling or rendering configuration fails.
    func setDownlinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws {
        try await setQualityLevel(
            level,
            downlink: true
        )
    }

    /// Changes the requested uplink or downlink quality level.
    ///
    /// - Parameters:
    ///   - level: The requested transport quality level.
    ///   - downlink: Whether to change downlink output rather than uplink encoding.
    ///
    /// - Throws: An error if the state is invalid, an operation conflicts or is cancelled, or the
    ///   level cannot be applied.
    private func setQualityLevel(
        _ level: RealtimeQualityLevel,
        downlink: Bool
    ) async throws {
        try await lifecycleManager.run(kind: .configuration) { [self] token in
            let state = await lifecycleManager.currentState
            try token.ensureCurrent()

            guard state.connectionState == .generating,
                let taskID = state.taskID,
                streamController.qualityConfiguration != nil
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Quality levels can only be changed while generating"
                )
            }

            try await connectionManager.applyQualityLevel(
                level,
                downlink: downlink,
                taskID: taskID,
                ensureCurrent: {
                    try token.ensureCurrent()
                }
            )
        }
    }

    // MARK: - Listeners

    /// Sets the realtime state listener.
    ///
    /// - Parameter listener: The state change handler, or `nil` to remove the listener.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async {
        await lifecycleManager.setStateListener(listener)
    }

    func setRoomMessageListener(_ listener: RealtimeRoomMessageListener?) async {
        await streamController.setRoomMessageListener(listener)
    }

    /// Sets serialized remote PCM and processed video output without changing playback.
    ///
    /// - Parameter listener: The output handler, or `nil` to stop output.
    ///
    /// - Throws: An error if the current remote audio listener cannot be configured.
    func setRemoteMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) async throws {
        try await renderController.setRemoteMediaFrameListener(listener)
    }

    /// Sets the uplink video statistics listener.
    ///
    /// - Parameter listener: A main-actor handler that receives `nil` when unpublished or
    ///   disconnected. Pass `nil` to remove it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) {
        streamController.setUplinkVideoStatisticsListener(listener)
    }

    /// Sets the downlink video statistics listener.
    ///
    /// - Parameter listener: A main-actor handler that receives `nil` when the result stream is
    ///   cleared. Pass `nil` to remove it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) {
        streamController.setDownlinkVideoStatisticsListener(listener)
    }

    /// Sets the network quality listener.
    ///
    /// - Parameter listener: The uplink and downlink quality handler, or `nil` to remove it.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) {
        streamController.setNetworkQualityListener(listener)
    }

    /// Sets the device performance alarm listener.
    ///
    /// - Parameter listener: The device performance alarm handler, or `nil` to remove it.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) {
        streamController.setPerformanceAlarmListener(listener)
    }

    // MARK: - Playback

    /// Sets the local media preview volume.
    ///
    /// - Parameter volume: The preview volume, in the range `0...1`.
    ///
    /// - Throws: An error if the volume is outside the valid range.
    func setLocalAudioVolume(
        _ volume: Float
    ) async throws {
        do {
            try Self.validateAudioVolume(volume)
            await mediaController.setLocalAudioVolume(volume)
        } catch {
            throw await reportError(error)
        }
    }

    /// Sets the remote audio playback volume.
    ///
    /// The setting is retained before connection or subscription and applied before remote audio
    /// playback. Call this method after creating the local stream to override its initial volume.
    ///
    /// - Parameter volume: The remote playback volume, in the range `0...1`.
    ///
    /// - Throws: An error if the volume is invalid or RTC volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Float
    ) async throws {
        do {
            try Self.validateAudioVolume(volume)
            try streamController.setRemoteAudioVolume(volume)
        } catch {
            throw await reportError(XmaxError.from(error))
        }
    }

    /// Enables or disables remote frame interpolation and updates the return dimensions.
    ///
    /// - Parameter enabled: Whether to enable remote frame interpolation.
    ///
    /// - Throws: An error if interpolation is unsupported, an operation conflicts or is cancelled,
    ///   or signaling or rendering configuration fails.
    func setFrameInterpolationEnabled(
        _ enabled: Bool
    ) async throws {
        try await lifecycleManager.run(kind: .configuration) { [self] token in
            let state = await lifecycleManager.currentState
            let format = await mediaController.currentVideoFormat
            try token.ensureCurrent()

            try await connectionManager.setFrameInterpolationEnabled(
                enabled,
                mediaFormat: format,
                taskID: state.taskID,
                ensureCurrent: {
                    try token.ensureCurrent()
                }
            )
        }
    }

    // MARK: - Local Media？

    /// Creates a local camera stream and starts its preview.
    ///
    /// Bind the returned track to a preview view. The state becomes `ready` after the bound view
    /// receives a valid frame.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture and encoding format.
    ///   - position: The camera position to use initially.
    ///   - useMicrophone: Whether to request microphone access during creation and capture audio
    ///     while connected.
    ///
    /// - Returns: A media stream containing the local camera video track.
    ///
    /// - Throws: An error if configuration is invalid, a required permission is denied, an
    ///   operation conflicts, or capture cannot start.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        position: CameraPosition,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createLocalMediaStream(source: .camera) { [self] token in
            let stream = try await mediaController.createLocalCameraStream(
                videoFormat: videoFormat,
                position: position,
                useMicrophone: useMicrophone
            )
            try token.ensureCurrent()
            return stream
        }
    }

    /// Updates a ready, disconnected camera format while preserving stream and view bindings.
    ///
    /// - Parameter videoFormat: The supported camera dimensions, frame rate, and encoding settings.
    ///
    /// - Throws: An error if the state or format is invalid, an operation conflicts, or device
    ///   configuration fails.
    func updateCameraFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws {
        try await updateCameraFormat { _ in
            videoFormat
        }
    }

    /// Updates camera dimensions while preserving frame rate and encoding settings.
    ///
    /// - Parameter preset: The requested resolution preset.
    ///
    /// - Throws: An error if the state or preset is invalid, an operation conflicts, or capture
    ///   configuration fails.
    func updateCameraFormat(
        _ preset: RealtimeCameraPreset
    ) async throws {
        try await updateCameraFormat { current in
            current.resized(
                width: Int(preset.size.width),
                height: Int(preset.size.height)
            )
        }
    }

    /// Updates the camera format using its current settings.
    ///
    /// - Parameter resolve: A closure deriving the requested format from the current camera format.
    ///
    /// - Throws: An error if the camera is not ready, realtime is connected, or configuration
    ///   fails.
    private func updateCameraFormat(
        resolve: @escaping @Sendable (RealtimeVideoFormat) -> RealtimeVideoFormat
    ) async throws {
        try await lifecycleManager.run(kind: .media) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before updating the camera format"
            )

            guard await lifecycleManager.currentState.connectionState == .ready,
                let current = await currentCameraVideoFormat
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera preview must be ready before updating its format"
                )
            }
            try token.ensureCurrent()

            try await mediaController.updateCameraFormat(resolve(current))
            try token.ensureCurrent()
        }
    }

    /// Stops the local camera stream.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopLocalCameraStream() async throws {
        try await stopLocalMediaStream(source: .camera) { [mediaController] in
            await mediaController.stopLocalCameraStream()
        }
    }

    /// Switches between the front and rear cameras.
    ///
    /// During generation, XmaxSDK stops the current task, switches cameras, and resumes with cached
    /// conditions. The RTC connection remains open. Switching is unavailable while connection or
    /// generation startup is in progress.
    ///
    /// - Returns: The local stream with its existing video track and updated camera position.
    ///
    /// - Throws: An error if no camera stream exists, realtime startup is in progress, or camera
    ///   switching or generation restart fails.
    func switchCamera() async throws -> RealtimeMediaStream {
        let current = await lifecycleManager.currentState
        guard current.connectionState != .connecting, current.connectionState != .disconnecting else {
            throw await reportError(
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime is transitioning"
                )
            )
        }

        guard current.connectionState == .generating || !streamController.hasGenerationTask else {
            throw await reportError(
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime generation is starting"
                )
            )
        }

        return try await lifecycleManager.run(kind: .cameraSwitch) { [self] token in
            let current = await lifecycleManager.currentState
            guard current.connectionState != .connecting, current.connectionState != .disconnecting else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime is transitioning"
                )
            }

            let wasGenerating = current.connectionState == .generating
            guard wasGenerating || !streamController.hasGenerationTask else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime generation is starting"
                )
            }

            if wasGenerating {
                token.setFailureScope(.connection)
                try await generationManager.stop(taskID: current.taskID ?? "")
                await mediaController.setLocalAudioPreviewMuted(false)
                try await lifecycleManager.commit(
                    RealtimeState(
                        connectionState: .connected,
                        sessionID: current.sessionID
                    ),
                    token: token
                )
            }

            let stream = try await mediaController.switchCamera()
            try token.ensureCurrent()
            try await connectionManager.reconcileFrameInterpolation(
                for: stream.videoTrack?.videoFormat
            )

            if wasGenerating {
                try await Task.sleep(nanoseconds: 500_000_000)
                try await performStartGeneration(
                    context: nil,
                    faceRestoration: await generationManager.cachedFaceRestoration,
                    token: token
                )
            }

            return stream
        }
    }

    /// Creates a continuous video frame stream from encoded image data.
    ///
    /// The stream retains the media aspect ratio; the model selects the generation canvas
    /// separately.
    ///
    /// - Parameter imageData: Encoded image data in a supported format, such as JPEG or PNG.
    ///
    /// - Returns: A media stream containing the local image video track.
    ///
    /// - Throws: An error if configuration is invalid, an operation conflicts, or image processing
    ///   fails.
    func createLocalImageStream(
        imageData: Data
    ) async throws -> RealtimeMediaStream {
        try await createLocalMediaStream(source: .image) { [self] token in
            let stream = try await mediaController.createLocalImageStream(imageData: imageData)
            try token.ensureCurrent()
            return stream
        }
    }

    #if canImport(UIKit)

    /// Creates a continuous video frame stream from a UIKit image.
    ///
    /// The stream retains the media aspect ratio; the model selects the generation canvas
    /// separately.
    ///
    /// - Parameter image: The UIKit image to use as local input.
    ///
    /// - Returns: A media stream containing the local image video track.
    ///
    /// - Throws: An error if configuration is invalid, an operation conflicts, or image processing
    ///   fails.
    func createLocalImageStream(
        image: UIImage
    ) async throws -> RealtimeMediaStream {
        let decodedImage = try ImageManager().decode(image)
        return try await createLocalImageStream(decodedImage: decodedImage)
    }

    #endif

    /// Creates a continuous local frame stream from a decoded image.
    ///
    /// - Parameter decodedImage: The decoded, orientation-corrected image.
    ///
    /// - Returns: A media stream containing the local image video track.
    ///
    /// - Throws: An error if local media cannot change, the operation is cancelled, or image stream
    ///   creation fails.
    func createLocalImageStream(
        decodedImage: any DecodedImage
    ) async throws -> RealtimeMediaStream {
        try await createLocalMediaStream(source: .image) { [self] token in
            let stream = try await mediaController.createLocalImageStream(decodedImage: decodedImage)
            try token.ensureCurrent()
            return stream
        }
    }

    /// Creates a continuous video frame stream from a local image file.
    ///
    /// The stream retains the media aspect ratio; the model selects the generation canvas
    /// separately.
    ///
    /// - Parameter fileURL: The local image file URL.
    ///
    /// - Returns: A media stream containing the local image video track.
    ///
    /// - Throws: An error if configuration is invalid, an operation conflicts, or image processing
    ///   fails.
    func createLocalImageStream(
        fileURL: URL
    ) async throws -> RealtimeMediaStream {
        try await createLocalMediaStream(source: .image) { [self] token in
            let stream = try await mediaController.createLocalImageStream(fileURL: fileURL)
            try token.ensureCurrent()
            return stream
        }
    }

    /// Stops the local image stream.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopLocalImageStream() async throws {
        try await stopLocalMediaStream(source: .image) { [mediaController] in
            await mediaController.stopLocalImageStream()
        }
    }

    /// Creates a looping audio and video stream from a local video file.
    ///
    /// The stream retains the video's display aspect ratio and uses the model's default frame rate.
    /// The generation canvas is resolved separately.
    ///
    /// - Parameter fileURL: The local video file URL.
    ///
    /// - Returns: A media stream containing the local file video track.
    ///
    /// - Throws: An error if configuration is invalid, an operation conflicts, or video processing
    ///   fails.
    func createLocalVideoStream(
        fileURL: URL
    ) async throws -> RealtimeMediaStream {
        try await createLocalMediaStream(source: .video) { [self] token in
            let stream = try await mediaController.createLocalVideoStream(fileURL: fileURL)
            try token.ensureCurrent()
            return stream
        }
    }

    /// Stops the local file video stream.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopLocalVideoStream() async throws {
        try await stopLocalMediaStream(source: .video) { [mediaController] in
            await mediaController.stopLocalVideoStream()
        }
    }

    /// Binds an external video source, preserving its frame rate and resolving media dimensions.
    ///
    /// - Parameter source: The external source owned by your app.
    ///
    /// - Returns: A local stream for SDK preview and generation.
    ///
    /// - Throws: An error if the format is invalid, an operation conflicts, or source binding
    ///   fails.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource
    ) async throws -> RealtimeMediaStream {
        try await createLocalMediaStream(source: .external) { [self] token in
            let stream = try await mediaController.createExternalVideoStream(source: source)
            try token.ensureCurrent()
            return stream
        }
    }

    /// Unbinds the external video source.
    ///
    /// - Throws: An error if realtime is still connected, an operation conflicts, or the operation
    ///   is cancelled.
    func stopExternalVideoStream() async throws {
        try await stopLocalMediaStream(source: .external) { [mediaController] in
            await mediaController.stopExternalVideoStream()
        }
    }

    // MARK: - Connection

    /// Establishes a realtime connection using a local stream created by this manager.
    ///
    /// - Parameter localStream: The active local media stream owned by this manager.
    ///
    /// - Returns: The connection's remote stream, which can be bound to a result view.
    ///
    /// - Throws: An error if the local stream is invalid, a connection exists, an operation
    ///   conflicts or is cancelled, or connection setup fails.
    func connect(
        localStream: RealtimeMediaStream
    ) async throws -> RealtimeMediaStream {
        try await lifecycleManager.run(kind: .connection) { [self] token in
            try await performConnect(
                localStream: localStream,
                token: token,
                completesOperation: true
            )
        }
    }

    /// Disconnects realtime while preserving the local media preview.
    func disconnect() async {
        await lifecycleManager.disconnect()
    }

    /// Disconnects for the specified reason while preserving available local media.
    ///
    /// - Parameter reason: The reason for disconnection, such as an orientation change.
    func disconnect(
        reason: RealtimeReason
    ) async {
        await lifecycleManager.disconnect(reason: reason)
    }

    /// Closes the realtime lifecycle and releases the connection, local media, and RTC engine.
    ///
    /// Concurrent calls await the same cleanup task. Local streams can be created again after
    /// closing completes.
    func close() async {
        await lifecycleManager.terminate(.all)
    }

    // MARK: - Generation

    @discardableResult
    func stopGeneration() async throws -> String? {
        try await lifecycleManager.stopGeneration()
    }

    /// Starts generation or updates conditions for the active task.
    ///
    /// - Parameters:
    ///   - context: The generation conditions. Required for the first request; `nil` reuses cached
    ///     conditions thereafter.
    ///   - faceRestoration: Whether to restore the original face.
    ///
    /// - Throws: An error if conditions are invalid or generation startup or an update fails.
    func startGeneration(
        context: RealtimeContext?,
        faceRestoration: Bool = false
    ) async throws {
        try await lifecycleManager.run(kind: .generation) { [self] token in
            let current = await lifecycleManager.currentState
            try token.ensureCurrent()

            let measuresStartup = current.connectionState == .connected
            if measuresStartup {
                timing.begin()
            }

            do {
                try await performStartGeneration(
                    context: context,
                    faceRestoration: faceRestoration,
                    token: token
                )
            } catch {
                if measuresStartup {
                    timing.finishFailure(error)
                }
                throw error
            }
        }
    }

    /// Connects the current local stream if needed and starts generation.
    ///
    /// Local video file playback continues during connection and generation. An existing connection
    /// is reused. Bind the returned remote stream to a realtime video view to display results.
    ///
    /// - Parameters:
    ///   - localStream: The active local media stream owned by this manager.
    ///   - context: The generation conditions. Required for the first request.
    ///   - faceRestoration: Whether to restore the original face.
    ///
    /// - Returns: The remote media stream for the current RTC connection.
    ///
    /// - Throws: An error if the local stream is invalid or connection or generation startup fails.
    func startGeneration(
        localStream: RealtimeMediaStream,
        context: RealtimeContext?,
        faceRestoration: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await lifecycleManager.run(kind: .generation) { [self] token in
            let initialState = await lifecycleManager.currentState
            let hasConnection = await connectionManager.currentSessionID != ""
            try token.ensureCurrent()

            let measuresStartup = initialState.connectionState != .connecting
                && initialState.connectionState != .disconnecting
            if measuresStartup {
                timing.begin()
            }

            do {
                guard await mediaController.owns(localStream) else {
                    throw XmaxError(
                        code: .invalidConfiguration,
                        message: "The local stream must be created and started by this realtime manager"
                    )
                }
                try token.ensureCurrent()

                try await generationManager.validateContext(context)
                try token.ensureCurrent()

                let remoteStream: RealtimeMediaStream
                if hasConnection {
                    guard let activeRemoteStream = await connectionManager.currentRemoteStream else {
                        throw XmaxError(
                            code: .rtcError,
                            message: "Realtime connection has no remote stream"
                        )
                    }

                    remoteStream = activeRemoteStream
                } else {
                    await mediaController.setLocalAudioPreviewMuted(true)
                    remoteStream = try await performConnect(
                        localStream: localStream,
                        token: token
                    )
                }

                try await performStartGeneration(
                    context: context,
                    faceRestoration: faceRestoration,
                    token: token
                )
                return remoteStream
            } catch {
                if measuresStartup {
                    timing.finishFailure(error)
                }
                throw error
            }
        }
    }

    /// Starts generation or updates the active task's conditions.
    ///
    /// - Parameters:
    ///   - context: The requested conditions, or `nil` to reuse the most recent successful
    ///     conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - token: The token used to verify that the current operation remains valid.
    ///
    /// - Throws: An error if the connection or conditions are invalid, the operation is cancelled,
    ///   or generation startup or an update fails.
    private func performStartGeneration(
        context: RealtimeContext?,
        faceRestoration: Bool,
        token: XmaxRealtimeLifecycleManager.Token
    ) async throws {
        try token.ensureCurrent()
        let sessionID = await connectionManager.currentSessionID
        let current = await lifecycleManager.currentState

        guard !sessionID.isEmpty,
            current.connectionState == .connected || current.connectionState == .generating,
            let videoFormat = await mediaController.currentVideoFormat
        else {
            throw XmaxError(
                code: .rtcError,
                message: "Realtime connection is not open"
            )
        }

        let generationSize = try mediaService.resolveGenerationSize(videoFormat.size)
        let generationFormat = videoFormat.resized(
            width: Int(generationSize.width),
            height: Int(generationSize.height)
        )
        let paddingContain = videoFormat.width * generationFormat.height != videoFormat.height * generationFormat.width
        try token.ensureCurrent()

        if current.connectionState == .generating, let taskID = current.taskID {
            try await generationManager.update(
                taskID: taskID,
                videoFormat: videoFormat,
                targetSize: nil,
                context: context,
                faceRestoration: faceRestoration,
                generationVideoFormat: generationFormat,
                paddingContain: paddingContain,
                ensureCurrent: {
                    try token.ensureCurrent()
                }
            )
            try token.ensureCurrent()
            return
        }

        try await generationManager.validateContext(context)
        try token.ensureCurrent()
        token.setFailureScope(.connection)

        do {
            await mediaController.setLocalAudioPreviewMuted(true)
            let includeAudio = await mediaController.hasAudio
            try token.ensureCurrent()
            try streamController.publishLocalStream(includeAudio: includeAudio)
            let taskID = try await generationManager.start(
                videoFormat: videoFormat,
                targetSize: await connectionManager.currentTargetSize,
                context: context,
                faceRestoration: faceRestoration,
                generationVideoFormat: generationFormat,
                paddingContain: paddingContain,
                ensureCurrent: {
                    try token.ensureCurrent()
                }
            )
            try token.ensureCurrent()

            guard await connectionManager.currentSessionID == sessionID else {
                throw XmaxError(
                    code: .cancelled,
                    message: "Realtime connection was cancelled"
                )
            }

            await connectionManager.completeInitialQuality()

            if options.isAdaptiveQualityEnabled {
                streamController.setAdaptiveQualityListener { [weak self] quality, time in
                    Task {
                        await self?.adaptQuality(
                            quality,
                            sampledAt: time,
                            taskID: taskID
                        )
                    }
                }
            }

            try await lifecycleManager.complete(
                RealtimeState(
                    connectionState: .generating,
                    sessionID: sessionID,
                    taskID: taskID
                ),
                token: token
            )
            timing.finish(taskID: taskID)
        } catch {
            await mediaController.setLocalAudioPreviewMuted(false)
            throw error
        }
    }
}

private extension XmaxRealtimeManager {

    /// Attempts automatic adaptation for the current task, skipping samples while busy.
    ///
    /// - Parameters:
    ///   - sample: The sampled uplink and downlink network quality.
    ///   - sampledAt: The monotonic sample time, in seconds.
    ///   - taskID: The identifier of the task associated with this sample.
    func adaptQuality(
        _ sample: RealtimeNetworkQuality,
        sampledAt: TimeInterval,
        taskID: String
    ) async {
        guard !qualityPending else {
            return
        }

        qualityPending = true
        defer {
            qualityPending = false
        }

        do {
            let accepted = try await lifecycleManager.runAdaptiveConfiguration { [self] token in
                let state = await lifecycleManager.currentState
                try token.ensureCurrent()

                guard state.taskID == taskID, state.connectionState == .generating else {
                    return
                }

                let change = streamController.proposeQuality(
                    sample,
                    sampledAt: sampledAt
                )

                if let level = change.uplink {
                    try? await connectionManager.applyQualityLevel(
                        level,
                        downlink: false,
                        taskID: taskID,
                        ensureCurrent: {
                            try token.ensureCurrent()
                        }
                    )
                }

                try token.ensureCurrent()

                if let level = change.downlink {
                    try? await connectionManager.applyQualityLevel(
                        level,
                        downlink: true,
                        taskID: taskID,
                        ensureCurrent: {
                            try token.ensureCurrent()
                        }
                    )
                }
            }

            if !accepted {
                streamController.resetQualitySamples()
            }
        } catch {
            // Do not let cancellation or disconnection reset samples for a newer task.
            if !Task.isCancelled, await lifecycleManager.currentState.taskID == taskID {
                streamController.resetQualitySamples()
            }
        }
    }

    /// Establishes a realtime connection for the local stream.
    ///
    /// - Parameters:
    ///   - localStream: The active local stream created by this manager.
    ///   - token: The validity token for the connection operation.
    ///   - completesOperation: Whether to complete the operation when connected or leave it active
    ///     for generation startup.
    ///
    /// - Returns: The remote media stream for the session.
    ///
    /// - Throws: An error if a connection exists, the stream is invalid, the operation is
    ///   cancelled, or session or RTC setup fails.
    func performConnect(
        localStream: RealtimeMediaStream,
        token: XmaxRealtimeLifecycleManager.Token,
        completesOperation: Bool = false
    ) async throws -> RealtimeMediaStream {
        let current = await lifecycleManager.currentState
        guard await connectionManager.currentSessionID == "",
            current.connectionState != .connecting,
            current.connectionState != .disconnecting
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Realtime connection is already open"
            )
        }

        guard await mediaController.owns(localStream) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "The local stream must be created and started by this realtime manager"
            )
        }

        try await mediaController.updateCameraOrientation()
        try token.ensureCurrent()

        guard let videoFormat = localStream.videoTrack?.videoFormat else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Local video format is unavailable"
            )
        }

        token.setFailureScope(.connection)
        try await generationManager.reset()
        try token.ensureCurrent()
        try await lifecycleManager.commit(
            RealtimeState(connectionState: .connecting),
            token: token
        )
        let targetSize = try await connectionManager.prepareQuality(
            baseline: videoFormat,
            options: options,
            ensureCurrent: {
                try token.ensureCurrent()
            }
        )
        try token.ensureCurrent()

        try await mediaController.startMicrophoneCapture()
        try token.ensureCurrent()

        let remoteStream = try await connectionManager.connect(
            model: options.model,
            videoFormat: videoFormat,
            targetSize: targetSize,
            includeLocalAudio: await mediaController.hasAudio,
            isCurrent: {
                token.isCurrent
            },
            onHeartbeatFailure: { [weak self] sessionID, error in
                await self?.handleHeartbeatFailure(
                    sessionID: sessionID,
                    error: error
                )
            }
        )
        try token.ensureCurrent()

        let sessionID = await connectionManager.currentSessionID
        guard !sessionID.isEmpty else {
            throw XmaxError(
                code: .cancelled,
                message: "Realtime connection was cancelled"
            )
        }

        let connectedState = RealtimeState(
            connectionState: .connected,
            sessionID: sessionID
        )
        if completesOperation {
            try await lifecycleManager.complete(
                connectedState,
                token: token
            )
        } else {
            try await lifecycleManager.commit(
                connectedState,
                token: token
            )
        }

        return remoteStream
    }

    /// Prepares a local stream for preview and generation.
    ///
    /// Camera readiness is updated after the first valid preview frame.
    ///
    /// - Parameters:
    ///   - source: The kind of local media being created.
    ///   - prepare: The asynchronous media creation operation receiving the current validity token.
    ///
    /// - Returns: The prepared local stream.
    ///
    /// - Throws: An error if a local stream exists, realtime is connected, the operation is
    ///   cancelled, or media preparation fails.
    func createLocalMediaStream(
        source: RealtimeMediaSource,
        prepare: @escaping @Sendable (XmaxRealtimeLifecycleManager.Token) async throws -> RealtimeMediaStream
    ) async throws -> RealtimeMediaStream {
        return try await lifecycleManager.run(kind: .media) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Local \(source.rawValue) stream is unavailable during a realtime connection"
            )

            guard await mediaController.currentTrack == nil else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Stop the current local media stream before creating another one"
                )
            }
            try token.ensureCurrent()

            errorManager.invalidatePendingFailures()
            try await lifecycleManager.commit(
                RealtimeState(connectionState: .preparing),
                token: token
            )
            try token.ensureCurrent()

            let stream = try await prepare(token)
            try token.ensureCurrent()
            token.setFailureScope(.all)

            if let track = stream.videoTrack {
                await MainActor.run {
                    track.orientationChangeHandler = { [weak self, weak track] changedAxis in
                        guard let track else {
                            return
                        }
                        Task {
                            await self?.handleOrientationChange(
                                for: track,
                                changedAxis: changedAxis
                            )
                        }
                    }
                }

                try token.ensureCurrent()
            }

            try await connectionManager.reconcileFrameInterpolation(
                for: stream.videoTrack?.videoFormat
            )
            try token.ensureCurrent()
            try streamController.setRemoteAudioVolume(source == .video ? 1 : 0)

            if source == .camera {
                await mediaController.setCameraPreviewReadyHandler { [lifecycleManager] isCurrent in
                    Task {
                        await lifecycleManager.localPreviewDidBecomeReady(isCurrent: isCurrent)
                    }
                }
            } else {
                try await lifecycleManager.complete(
                    RealtimeState(connectionState: .ready),
                    token: token
                )
            }

            return stream
        }
    }

    /// Stops one media source and publishes the remaining local media state.
    ///
    /// - Parameters:
    ///   - source: The kind of local media being stopped.
    ///   - stop: The operation that releases only the requested source.
    ///
    /// - Throws: An error if realtime is connected, an operation conflicts, or the operation is
    ///   cancelled.
    func stopLocalMediaStream(
        source: RealtimeMediaSource,
        stop: @escaping @Sendable () async -> Void
    ) async throws {
        try await lifecycleManager.run(kind: .media) { [self] token in
            let streamName = source == .external ? "external video" : "local \(source.rawValue)"
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before stopping the \(streamName) stream"
            )

            token.setFailureScope(.all)
            await stop()
            try token.ensureCurrent()

            errorManager.invalidatePendingFailures()
            let hasLocalMedia = await mediaController.currentTrack != nil
            try await lifecycleManager.complete(
                RealtimeState(connectionState: hasLocalMedia ? .ready : .idle),
                token: token
            )
        }
    }

    /// Verifies that no realtime connection prevents local media changes.
    ///
    /// - Parameter message: The error message to use when media changes are unavailable.
    ///
    /// - Throws: An error if a session exists or connection setup or teardown is in progress.
    func ensureLocalMediaCanChange(
        message: String
    ) async throws {
        let current = await lifecycleManager.currentState
        guard await connectionManager.currentSessionID == "",
            current.connectionState != .connecting,
            current.connectionState != .disconnecting
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: message
            )
        }
    }

    /// Updates media orientation and disconnects when switching between portrait and landscape.
    ///
    /// - Parameters:
    ///   - track: The local track reporting an orientation change.
    ///   - changedAxis: Whether the change switches between portrait and landscape.
    func handleOrientationChange(
        for track: RealtimeVideoTrack,
        changedAxis: Bool
    ) async {
        guard await mediaController.currentTrack === track else {
            return
        }

        let disconnection = changedAxis
            ? await lifecycleManager.beginDisconnect(reason: .orientationChanged)
            : nil

        if await mediaController.currentTrack === track {
            do {
                try await mediaController.updateCameraOrientation()
            } catch {
                if await mediaController.currentTrack === track {
                    await lifecycleManager.terminate(
                        with: XmaxError.from(error),
                        target: .all
                    )
                }
            }
        }

        await disconnection?.value
    }

    /// Terminates the current session after heartbeat failure, ignoring notifications from old
    /// sessions.
    ///
    /// - Parameters:
    ///   - sessionID: The identifier of the session whose heartbeat failed.
    ///   - error: The heartbeat request error.
    func handleHeartbeatFailure(
        sessionID: String,
        error: XmaxError
    ) async {
        guard await connectionManager.currentSessionID == sessionID else {
            return
        }

        await lifecycleManager.terminate(
            with: error,
            target: .connection
        )
    }

    /// Converts and logs an error.
    ///
    /// - Parameter error: The original error to log and convert.
    ///
    /// - Returns: The converted error.
    @discardableResult
    func reportError(
        _ error: any Error
    ) async -> XmaxError {
        let xmaxError = XmaxError.from(error)
        await errorManager.report(xmaxError)
        return xmaxError
    }

    /// Verifies that a volume is finite and within `0...1`.
    ///
    /// - Parameter volume: The playback volume to validate.
    ///
    /// - Throws: An error if the volume is nonfinite or out of range.
    static func validateAudioVolume(
        _ volume: Float
    ) throws {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Audio volume must be between 0 and 1"
            )
        }
    }
}
