//
//  CameraController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import Foundation

/// Coordinates camera capture, external uplink frames, and local preview.
final class CameraController: CameraControlling, @unchecked Sendable {

    /// The local camera track identifier.
    private static let localVideoTrackID = "video0"

    /// The RTC media adapter.
    private let rtcManager: any RtcManaging

    /// The camera and microphone permission manager.
    private let permissionManager: any PermissionManaging

    /// The camera capture manager.
    private let captureManager: any CameraCaptureManaging

    /// The model media sizing service.
    private let mediaService: any MediaServicing

    /// The camera video frame handler.
    private let videoFrameListener: MediaVideoFrameListener

    /// The camera media failure handler.
    private let errorListener: XmaxErrorListener

    /// The internal preview readiness handler.
    private var previewReadyHandler: CameraPreviewReadyHandler?

    /// The lock protecting camera, capture, and preview state.
    private let stateLock = NSLock()

    /// The active camera track.
    private var activeTrack: RealtimeVideoTrack?

    /// The camera preview resources.
    private var preview: Preview?

    /// Whether the camera has produced a valid frame.
    private var hasCapturedFrame = false

    /// Whether a preview view is attached.
    private var isPreviewAttached = false

    /// Whether this camera input requests microphone access.
    private var storedUseMicrophone = false

    /// Whether RTC microphone capture is active.
    private var isMicrophoneCapturing = false

    /// The queue serializing format and orientation updates.
    @MainActor private var formatUpdateTask: Task<Void, any Error>?

    /// The applied orientation used to resolve output dimensions.
    @MainActor private var appliedOrientation: CameraOrientation?

    /// Creates a camera controller with system capture and permissions.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC video and microphone adapter.
    ///   - mediaService: The model sizing service.
    ///   - videoFrameListener: The camera video frame handler.
    ///   - errorListener: The capture failure handler.
    @MainActor
    convenience init(
        rtcManager: any RtcManaging,
        mediaService: any MediaServicing = MediaService(),
        videoFrameListener: @escaping MediaVideoFrameListener,
        errorListener: @escaping XmaxErrorListener
    ) {
        self.init(
            rtcManager: rtcManager,
            permissionManager: PermissionManager(),
            mediaService: mediaService,
            captureManager: CameraCaptureManager(),
            videoFrameListener: videoFrameListener,
            errorListener: errorListener
        )
    }

    /// Creates a camera controller with the specified dependencies.
    init(
        rtcManager: any RtcManaging,
        permissionManager: any PermissionManaging,
        mediaService: any MediaServicing,
        captureManager: any CameraCaptureManaging,
        videoFrameListener: @escaping MediaVideoFrameListener = { _ in
        },
        errorListener: @escaping XmaxErrorListener = { _ in
        }
    ) {
        self.rtcManager = rtcManager
        self.permissionManager = permissionManager
        self.mediaService = mediaService
        self.captureManager = captureManager
        self.videoFrameListener = videoFrameListener
        self.errorListener = errorListener
    }

    /// The active camera track, if created.
    var currentTrack: RealtimeVideoTrack? {
        stateLock.withLock {
            activeTrack
        }
    }

    /// Whether the camera stream uses microphone input.
    var useMicrophone: Bool {
        stateLock.withLock {
            activeTrack != nil && storedUseMicrophone
        }
    }

    /// Sets a one-shot readiness handler requiring a valid frame and an attached preview.
    ///
    /// - Parameter handler: The readiness handler, or `nil` to remove it.
    func setPreviewReadyHandler(
        _ handler: CameraPreviewReadyHandler?
    ) {
        let track = stateLock.withLock {
            previewReadyHandler = handler
            return activeTrack
        }
        if let track {
            notifyPreviewReady(for: track)
        }
    }

    /// Creates and starts a local camera stream.
    ///
    /// - Parameters:
    ///   - videoFormat: The requested dimensions, frame rate, and encoding settings, subject to
    ///     model rules.
    ///   - position: The initial camera position.
    ///   - useMicrophone: Whether to request microphone access and capture audio while connected.
    ///
    /// - Returns: The local camera media stream.
    ///
    /// - Throws: An error if a camera stream exists, the format is invalid, permission is denied,
    ///   or capture fails.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        position: CameraPosition,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        guard currentTrack == nil else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Stop the current local camera stream before creating another one"
            )
        }

        let resolvedFormat = try resolveVideoFormat(videoFormat)
        let track = RealtimeVideoTrack(
            id: Self.localVideoTrackID,
            videoFormat: resolvedFormat,
            position: position
        )

        do {
            try await permissionManager.ensureCameraPermission()
            if useMicrophone {
                try await permissionManager.ensureMicrophonePermission()
            }

            try Task.checkCancellation()
            try rtcManager.useExternalVideoSource()
            try rtcManager.configureLocalVideoMirror(for: position)
            let preview = await makePreview(
                for: track,
                position: position
            )
            stateLock.withLock {
                activeTrack = track
                self.preview = preview
                storedUseMicrophone = useMicrophone
                hasCapturedFrame = false
                isPreviewAttached = false
            }

            try await captureManager.start(
                videoFormat: VideoFormat(
                    width: resolvedFormat.width,
                    height: resolvedFormat.height,
                    pixelFormat: .nv12
                ),
                frameRate: resolvedFormat.fps,
                position: position,
                frameListener: { [weak self] frame in
                    try self?.handleFrame(
                        frame,
                        track: track,
                        preview: preview
                    )
                },
                errorListener: { [weak self] error in
                    guard let self, currentTrack === track else {
                        return
                    }
                    errorListener(error)
                }
            )

            try Task.checkCancellation()
            return RealtimeMediaStream(
                id: StreamID.local.rawValue,
                videoTrack: track
            )
        } catch {
            await stopLocalCameraStream()
            throw XmaxError.from(error)
        }
    }

    /// Starts configured microphone capture without local audio playback.
    ///
    /// - Throws: An error if RTC audio configuration or microphone capture fails.
    func startMicrophoneCapture() throws {
        try stateLock.withLock {
            guard activeTrack != nil, storedUseMicrophone, !isMicrophoneCapturing else {
                return
            }
            // Retain stop eligibility on startup failure so cleanup can release a partially started device.
            isMicrophoneCapturing = true
            try rtcManager.startAudioCapture()
        }
    }

    /// Stops microphone capture while retaining its configuration.
    ///
    /// - Throws: An error if RTC microphone capture cannot stop.
    func stopMicrophoneCapture() throws {
        try stateLock.withLock {
            guard isMicrophoneCapturing else {
                return
            }
            try rtcManager.stopAudioCapture()
            isMicrophoneCapturing = false
        }
    }

    /// Stops camera and microphone capture and releases preview resources.
    func stopLocalCameraStream() async {
        do {
            try stopMicrophoneCapture()
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    停止麦克风采集失败 (Failed to Stop Microphone Capture)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }

        let resources = stateLock.withLock {
            let resources = (activeTrack, preview)
            activeTrack = nil
            preview = nil
            previewReadyHandler = nil
            storedUseMicrophone = false
            isMicrophoneCapturing = false
            hasCapturedFrame = false
            isPreviewAttached = false
            return resources
        }

        await captureManager.stop()
        resources.1?.dispatcher.reset()
        await MainActor.run {
            appliedOrientation = nil
            formatUpdateTask = nil
            if let track = resources.0 {
                VideoRenderRegistry.unregister(track)
            }
            resources.1?.presenter.clear()
        }
    }

    /// Switches cameras while retaining the video track.
    ///
    /// - Returns: The media stream with the updated camera track.
    ///
    /// - Throws: An error if capture is inactive or camera switching or mirroring fails.
    func switchCamera() async throws -> RealtimeMediaStream {
        guard let track = currentTrack, let position = track.position else {
            throw XmaxError(
                code: .rtcError,
                message: "Local camera preview is not started"
            )
        }

        let nextPosition: CameraPosition = position == .front ? .back : .front
        try await captureManager.switchCamera(to: nextPosition)

        do {
            try rtcManager.configureLocalVideoMirror(for: nextPosition)
        } catch {
            try? await captureManager.switchCamera(to: position)
            try? rtcManager.configureLocalVideoMirror(for: position)
            throw error
        }

        track.updatePosition(nextPosition)
        let preview = stateLock.withLock {
            self.preview
        }

        await preview?.presenter.setMirrored(nextPosition == .front)
        return RealtimeMediaStream(
            id: StreamID.local.rawValue,
            videoTrack: track
        )
    }

    /// Updates capture orientation and track dimensions for the window.
    ///
    /// - Parameter orientation: The requested window orientation.
    ///
    /// - Throws: An error if the model rejects the dimensions or capture configuration fails.
    func updateOrientation(
        _ orientation: CameraOrientation
    ) async throws {
        guard currentTrack != nil else {
            return
        }
        try await updateCapture(
            videoFormat: nil,
            orientation: orientation
        )
    }

    /// Updates the camera format while retaining orientation, position, and track.
    ///
    /// - Parameter videoFormat: The supported dimensions, capture frame rate, and encoding
    ///   settings.
    ///
    /// - Throws: An error if capture is inactive, the format is invalid, or configuration fails.
    func updateVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws {
        try await updateCapture(
            videoFormat: videoFormat,
            orientation: nil
        )
    }
}

private extension CameraController {

    /// Applies camera format and orientation updates in submission order.
    ///
    /// - Parameters:
    ///   - videoFormat: The requested format, or `nil` to change orientation only.
    ///   - orientation: The requested orientation, or `nil` to retain the current orientation.
    ///
    /// - Throws: An error if the track is stale, the format is unsupported, the call is cancelled,
    ///   or configuration fails.
    @MainActor
    func updateCapture(
        videoFormat: RealtimeVideoFormat?,
        orientation: CameraOrientation?
    ) async throws {
        guard let track = currentTrack else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Camera preview is not started"
            )
        }

        let previous = formatUpdateTask
        let task = Task { @MainActor [self] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard currentTrack === track, let current = track.videoFormat else {
                throw XmaxError(
                    code: .cancelled,
                    message: "Camera stream is no longer active"
                )
            }

            var requested = videoFormat ?? current
            if let orientation, let appliedOrientation,
                orientation.isLandscape != appliedOrientation.isLandscape
            {
                requested = current.resized(
                    width: current.height,
                    height: current.width
                )
            }

            let resolved = try resolveVideoFormat(requested)
            let output = try VideoFormat(
                width: resolved.width,
                height: resolved.height,
                pixelFormat: .nv12
            )

            if let orientation {
                try await captureManager.updateOrientation(
                    orientation,
                    videoFormat: output
                )
            } else if resolved != current {
                try await captureManager.updateFormat(
                    output,
                    frameRate: resolved.fps
                )
            }

            // Old-format callbacks have completed; update track metadata and queued preview frames together.
            guard currentTrack === track else {
                throw XmaxError(
                    code: .cancelled,
                    message: "Camera stream is no longer active"
                )
            }

            stateLock.withLock {
                preview?.dispatcher.reset()
                track.updateVideoFormat(resolved)
            }
            if let orientation {
                appliedOrientation = orientation
            }
        }

        formatUpdateTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The camera preview presenter and dispatcher.
    struct Preview: Sendable {

        /// The presenter for camera frames.
        let presenter: DecodedVideoPreviewPresenter

        /// The dispatcher delivering the latest frame to the main actor.
        let dispatcher: DecodedVideoPreviewDispatcher
    }

    /// Registers preview rendering for a camera track.
    ///
    /// - Parameters:
    ///   - track: The local camera track.
    ///   - position: The camera position determining preview mirroring.
    ///
    /// - Returns: The resources for subsequent preview delivery and cleanup.
    @MainActor
    func makePreview(
        for track: RealtimeVideoTrack,
        position: CameraPosition
    ) -> Preview {
        let presenter = DecodedVideoPreviewPresenter()
        presenter.setMirrored(position == .front)
        let preview = Preview(
            presenter: presenter,
            dispatcher: DecodedVideoPreviewDispatcher(presenter: presenter)
        )

        VideoRenderRegistry.register(
            track,
            binding: VideoRenderBinding(
                attachHandler: { [weak self] view, contentMode in
                    guard let videoView = view as? XmaxRealtimeVideoView else {
                        throw XmaxError(
                            code: .invalidConfiguration,
                            message: "Camera tracks require an XmaxRealtimeVideoView"
                        )
                    }

                    presenter.attach(
                        to: videoView,
                        contentMode: contentMode
                    )
                    self?.stateLock.withLock {
                        self?.isPreviewAttached = true
                    }

                    self?.notifyPreviewReady(for: track)
                },
                detachHandler: { [weak self] view in
                    if let videoView = view as? XmaxRealtimeVideoView {
                        presenter.detach(from: videoView)
                    }
                    self?.stateLock.withLock {
                        self?.isPreviewAttached = false
                    }
                }
            )
        )
        return preview
    }

    /// Delivers a current camera frame to preview and the media listener.
    ///
    /// - Parameters:
    ///   - frame: The oriented and resized capture frame.
    ///   - track: The camera track producing the frame.
    ///   - preview: The track's preview resources.
    ///
    /// - Throws: An error if the frame listener fails.
    func handleFrame(
        _ frame: VideoFrame,
        track: RealtimeVideoTrack,
        preview: Preview
    ) throws {
        let accepted = try stateLock.withLock {
            guard activeTrack === track else {
                return false
            }
            preview.dispatcher.enqueue(frame)
            hasCapturedFrame = true
            try videoFrameListener(frame)
            return true
        }
        if accepted {
            notifyPreviewReady(for: track)
        }
    }

    /// Notifies readiness once a valid frame and attached preview are available.
    ///
    /// - Parameter track: The camera track whose validity is checked.
    func notifyPreviewReady(
        for track: RealtimeVideoTrack
    ) {
        let shouldNotify = stateLock.withLock {
            activeTrack === track && hasCapturedFrame && isPreviewAttached
                && previewReadyHandler != nil
        }
        guard shouldNotify else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let handler = stateLock.withLock { () -> CameraPreviewReadyHandler? in
                guard activeTrack === track, hasCapturedFrame, isPreviewAttached else {
                    return nil
                }
                let handler = previewReadyHandler
                previewReadyHandler = nil
                return handler
            }

            handler? { [weak self] in
                guard let self else {
                    return false
                }
                return stateLock.withLock {
                    activeTrack === track
                }
            }
        }
    }

    /// Resolves camera output according to model sizing rules.
    ///
    /// - Parameter videoFormat: The requested camera format.
    ///
    /// - Returns: The output format retaining frame rate and encoding settings.
    ///
    /// - Throws: An error if the format is invalid or unsupported by the model.
    func resolveVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) throws -> RealtimeVideoFormat {
        try videoFormat.validate()
        let resolvedMediaSize = try mediaService.resolveMediaSize(
            CGSize(
                width: videoFormat.width,
                height: videoFormat.height
            ),
            source: .camera
        )
        let resolvedFormat = videoFormat.resized(
            width: Int(resolvedMediaSize.width),
            height: Int(resolvedMediaSize.height)
        )
        try resolvedFormat.validate()
        return resolvedFormat
    }
}
