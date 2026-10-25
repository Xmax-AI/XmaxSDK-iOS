//
//  XmaxRealtimeManaging.swift
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

/// An interface for local media, realtime connections, and video generation.
public protocol XmaxRealtimeManaging: Sendable {

    /// The realtime configuration.
    var options: RealtimeConfiguration {
        get
    }

    /// The current connection and generation state.
    var currentState: RealtimeState {
        get async
    }

    /// The camera's resolved media format, or `nil` without a camera stream. Uplink quality changes
    /// do not affect it.
    var currentCameraVideoFormat: RealtimeVideoFormat? {
        get async
    }

    /// The preset matching the camera dimensions, or `nil` if no camera or matching preset exists.
    var currentCameraPreset: RealtimeCameraPreset? {
        get async
    }

    /// Updates a ready, disconnected camera stream while preserving its track and view bindings.
    ///
    /// - Parameter videoFormat: The new capture dimensions, frame rate, and encoding settings.
    ///   Dimensions must match a supported model format.
    ///
    /// - Throws: An error if the state or format is invalid, another operation is active, or device
    ///   configuration fails.
    func updateCameraFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws

    /// Updates camera dimensions while preserving the current frame rate, bitrate, and encoding
    /// preference.
    ///
    /// - Parameter preset: A resolution preset supported by the model.
    ///
    /// - Throws: An error if the state or preset is invalid, another operation is active, or device
    ///   configuration fails.
    func updateCameraFormat(
        _ preset: RealtimeCameraPreset
    ) async throws

    /// The applied uplink level, or `nil` before connection completes or after disconnection
    /// begins.
    var uplinkQualityLevel: RealtimeQualityLevel? {
        get async
    }

    /// The submitted downlink level, or `nil` before connection completes or after disconnection
    /// begins.
    ///
    /// The server may begin returning the new dimensions after this value changes.
    var downlinkQualityLevel: RealtimeQualityLevel? {
        get async
    }

    /// Changes the uplink encoding level during generation without changing capture or generation
    /// dimensions.
    ///
    /// Automatic adaptation may subsequently change the level; a manual selection does not lock it.
    ///
    /// - Parameter level: The requested uplink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   encoder configuration fails.
    func setUplinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws

    /// Changes the downlink level during generation while retaining frame interpolation limits.
    ///
    /// Automatic adaptation may subsequently change the level; a manual selection does not lock it.
    ///
    /// - Parameter level: The requested downlink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   signaling or rendering configuration fails.
    func setDownlinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws

    /// Whether remote video frame interpolation is currently enabled.
    var isFrameInterpolationEnabled: Bool {
        get async
    }

    /// The local media preview volume, in the range `0...1`.
    var localAudioVolume: Float {
        get async
    }

    /// The remote audio playback volume, in the range `0...1`.
    ///
    /// Creating a video file stream sets this value to 1. Other local stream types set it to 0.
    var remoteAudioVolume: Float {
        get async
    }

    /// Sets the realtime state listener.
    ///
    /// - Parameter listener: The state change handler, or `nil` to remove the listener.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async

    /// Sets one listener for the result user's PCM and processed remote video.
    ///
    /// Audio is copied before remote-user mixing; video includes optional interpolation. Both use
    /// the receiver rendering timeline. Audio time advances by sample count between explicit
    /// discontinuities. Registration does not change playback volume or audio subscriptions.
    ///
    /// Call before generation or replace the listener while connected. Callbacks run on a dedicated
    /// serial background queue, in delivery order rather than cross-track PTS order. Forward packets
    /// promptly: pending output is bounded to 256 packets and 32 MiB, and discarded packets mark the
    /// next event of that track as discontinuous. A callback already running may finish after removal.
    ///
    /// - Parameter listener: The remote output handler, or `nil` to remove it and queued output.
    ///
    /// - Throws: An error if observation of an already-bound remote user cannot be configured.
    func setRemoteMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) async throws

    /// Sets the uplink video statistics listener.
    ///
    /// - Parameter listener: A main-actor handler that receives `nil` when unpublished or
    ///   disconnected. Pass `nil` to remove it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) async

    /// Sets the downlink video statistics listener.
    ///
    /// - Parameter listener: A main-actor handler that receives `nil` when the result stream is
    ///   cleared. Pass `nil` to remove it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) async

    /// Sets the network quality listener.
    ///
    /// - Parameter listener: The uplink and downlink quality handler, or `nil` to remove it.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) async

    /// Sets the device performance alarm listener.
    ///
    /// - Parameter listener: The device performance alarm handler, or `nil` to remove it.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) async

    /// Sets the local media preview volume.
    ///
    /// - Parameter volume: The preview volume, in the range `0...1`.
    ///
    /// - Throws: An error if the volume is outside the valid range.
    func setLocalAudioVolume(
        _ volume: Float
    ) async throws

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
    ) async throws

    /// Enables or disables frame interpolation for remote video.
    ///
    /// This setting overrides the initial configuration. Enabling interpolation requests reduced
    /// output dimensions; disabling it restores the dimensions for the current quality level
    /// without reconnecting or restarting generation. Original frames remain visible while output
    /// dimensions change.
    ///
    /// - Parameter enabled: Whether to enable remote video frame interpolation.
    ///
    /// - Throws: An error if another operation is active, interpolation is unsupported, or
    ///   signaling fails.
    func setFrameInterpolationEnabled(
        _ enabled: Bool
    ) async throws

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
        useMicrophone: Bool
    ) async throws -> RealtimeMediaStream

    /// Stops the local camera stream and updates media readiness.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopLocalCameraStream() async throws

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
    func switchCamera() async throws -> RealtimeMediaStream

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
    ) async throws -> RealtimeMediaStream

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
    ) async throws -> RealtimeMediaStream
    #endif

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
    ) async throws -> RealtimeMediaStream

    /// Stops the local image stream and updates media readiness.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopLocalImageStream() async throws

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
    ) async throws -> RealtimeMediaStream

    /// Stops the local file video stream and updates media readiness.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopLocalVideoStream() async throws

    /// Binds an external video source with optional audio for realtime generation.
    ///
    /// The source frame rate and encoding settings are retained. Media dimensions are limited by
    /// the model's maximum area and aligned to multiples of 4. Camera resolution buckets do not
    /// apply. Submit frames at `source.videoFormat` dimensions; XmaxSDK resizes them automatically
    /// and exposes the resolved format through `sink.videoFormat`.
    ///
    /// Sources declaring `hasAudio` can submit PCM for RTC upload. XmaxSDK doesn't request
    /// microphone permission or play submitted audio locally.
    ///
    /// The state becomes `ready` when binding completes, without waiting for a frame. Disconnection
    /// preserves frame delivery and preview. `stopExternalVideoStream()` and `close()` unbind the
    /// source without taking ownership of its capture resources.
    ///
    /// - Parameter source: The video source implemented and owned by your app.
    ///
    /// - Returns: A local stream for an `XmaxRealtimeVideoView` or realtime generation.
    ///
    /// - Throws: An error if the format is invalid, a stream already exists, an operation
    ///   conflicts, or source binding fails.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource
    ) async throws -> RealtimeMediaStream

    /// Stops external frame delivery and clears the SDK preview without taking ownership of capture
    /// resources.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopExternalVideoStream() async throws

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
    ) async throws -> RealtimeMediaStream

    /// Disconnects realtime while preserving the local media preview.
    func disconnect() async

    /// Disconnects for the specified reason while preserving available local media.
    ///
    /// - Parameter reason: The reason for disconnection, such as an orientation change.
    func disconnect(
        reason: RealtimeReason
    ) async

    /// Closes the realtime lifecycle and releases the connection, local media, and RTC engine.
    ///
    /// Concurrent calls await the same cleanup task. Local streams can be created again after
    /// closing completes.
    func close() async

    /// Starts generation or updates conditions for the active task.
    ///
    /// A newer call to either overload replaces an unfinished generation request. The replaced call
    /// ends with cancellation after required cleanup. Requests do not replace other operation kinds.
    /// Disconnecting or closing cancels pending requests without restarting generation afterward.
    ///
    /// - Parameters:
    ///   - context: The generation conditions. Required for the first request; `nil` reuses cached
    ///     conditions thereafter.
    ///   - faceRestoration: Whether to restore the original face. Sent with each request.
    ///
    /// - Throws: An error if conditions are invalid or generation startup or an update fails.
    func startGeneration(
        context: RealtimeContext?,
        faceRestoration: Bool
    ) async throws

    /// Connects the current local stream if needed and starts generation.
    ///
    /// Local video file playback continues during connection and generation. An existing connection
    /// is reused. Bind the returned remote stream to a realtime video view to display results.
    /// This overload uses the same request-replacement behavior as `startGeneration(context:faceRestoration:)`.
    ///
    /// - Parameters:
    ///   - localStream: The active local media stream owned by this manager.
    ///   - context: The generation conditions. Required for the first request.
    ///   - faceRestoration: Whether to restore the original face. Sent with each request.
    ///
    /// - Returns: The remote media stream for the current RTC connection.
    ///
    /// - Throws: An error if the local stream is invalid or connection or generation startup fails.
    func startGeneration(
        localStream: RealtimeMediaStream,
        context: RealtimeContext?,
        faceRestoration: Bool
    ) async throws -> RealtimeMediaStream
}
