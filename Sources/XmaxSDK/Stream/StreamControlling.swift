//
//  StreamControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The transport interface used by Core.
protocol StreamControlling: Sendable {

    /// The most recently stopped task in the current RTC room.
    var lastStoppedTaskID: String? { get }

    /// Registers a listener for decoded RTC room messages.
    func setRoomMessageListener(_ listener: RealtimeRoomMessageListener?) async

    /// The current media baseline and directional quality levels.
    var qualityConfiguration: QualityConfiguration? {
        get
    }

    /// Prepares quality levels from the media baseline and model history.
    ///
    /// - Parameters:
    ///   - baseline: The resolved local media baseline, unchanged by adaptation.
    ///   - model: The model identifier isolating quality history.
    ///   - minimumInputPixels: The model's minimum uplink area, in pixels.
    ///   - isAdaptiveQualityEnabled: Whether to adapt quality. Disabled connections start at L1
    ///     without using history.
    ///
    /// - Returns: The initial directional quality configuration.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        model: String,
        minimumInputPixels: Int,
        isAdaptiveQualityEnabled: Bool
    ) -> QualityConfiguration

    /// Sets internal quality sampling independently of the public network listener.
    ///
    /// - Parameter listener: The quality and monotonic sample time handler, or `nil` to remove it.
    func setAdaptiveQualityListener(
        _ listener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?
    )

    /// Proposes levels from the current network sample.
    ///
    /// - Parameters:
    ///   - quality: The current directional network quality.
    ///   - sampledAt: The monotonic sample time, in seconds.
    ///
    /// - Returns: The candidate levels satisfying sample and cooldown requirements.
    func proposeQuality(
        _ quality: RealtimeNetworkQuality,
        sampledAt: TimeInterval
    ) -> QualityChange

    /// Commits adjustment results, persisting successful levels.
    ///
    /// - Parameters:
    ///   - downlink: Whether this is downlink rather than uplink.
    ///   - level: The attempted quality level.
    ///   - success: Whether configuration succeeded.
    func completeQuality(
        downlink: Bool,
        level: RealtimeQualityLevel,
        success: Bool
    )

    /// Clears consecutive quality samples.
    func resetQualitySamples()

    /// Whether generation is starting or running.
    var hasGenerationTask: Bool {
        get
    }

    /// The remote generated audio volume.
    var remoteAudioVolume: Float {
        get
    }

    /// Sets the realtime video encoder configuration.
    ///
    /// - Parameter videoFormat: The RTC encoding dimensions and frame rate.
    ///
    /// - Throws: An error if the format is invalid or RTC configuration fails.
    func setVideoEncoderConfig(
        _ videoFormat: RealtimeVideoFormat
    ) throws

    /// Sets the uplink video statistics listener.
    ///
    /// - Parameter listener: The main-actor handler, receiving `nil` when unpublished or
    ///   disconnected. Pass `nil` to remove it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    )

    /// Sets the downlink video statistics listener.
    ///
    /// - Parameter listener: The main-actor handler, receiving `nil` when the result stream clears.
    ///   Pass `nil` to remove it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    )

    /// Sets the network quality listener.
    ///
    /// - Parameter listener: The directional network quality listener; pass `nil` to remove the
    ///   listener.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    )

    /// Sets the device performance listener.
    ///
    /// - Parameter listener: The device limitation and recovery listener; pass `nil` to remove the
    ///   listener.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    )

    /// Sets remote generated audio volume.
    ///
    /// - Parameter volume: The validated volume, in the range `0...1`.
    ///
    /// - Throws: An error if RTC volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Float
    ) throws

    /// Joins an RTC room and publishes local media.
    ///
    /// - Parameters:
    ///   - connection: The RTC room, user, token, and result user information.
    ///   - includeLocalAudio: Whether to publish audio alongside local video.
    ///   - ensureActive: The connection validity check across asynchronous boundaries; throw a
    ///     cancellation error if no longer current.
    ///
    /// - Throws: An error if cancelled or RTC join, configuration, or local publication fails.
    func connect(
        connection: RealtimeSessionConnection,
        includeLocalAudio: Bool,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws

    /// Disconnects the RTC room and releases media and generation state; safe when no room is
    /// active.
    func disconnect() async

    /// Publishes the local input and optional audio in the current room.
    func publishLocalStream(includeAudio: Bool) throws

    /// Suspends local RTC publication while keeping the room and input open.
    func unpublishLocalStream() throws

    /// Pushes external video during generation, ignoring frames without an active task.
    ///
    /// - Parameter frame: The local frame prepared for RTC.
    ///
    /// - Throws: An error if RTC is unready or video conversion fails.
    func pushLocalVideoFrame(
        _ frame: VideoFrame
    ) throws

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: The PCM frame prepared for RTC; ignored when local audio is unpublished.
    ///
    /// - Throws: An error if RTC is unready or audio conversion fails.
    func pushLocalAudioFrame(
        _ frame: AudioFrame
    ) throws

    /// Starts a generation task and its result stream confirmation.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation prompt and reference conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to contain input within the generation canvas.
    ///
    /// - Returns: The task awaiting remote result stream confirmation.
    ///
    /// - Throws: An error if the task or room is invalid, a task exists, or signaling fails or
    ///   times out.
    func beginGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) async throws -> Task<Void, any Error>

    /// Subscribes to generated audio after remote video is ready.
    ///
    /// - Throws: An error if the result stream is unconfirmed or RTC volume or subscription fails.
    func activateRemoteAudio() throws

    /// Sends an active task's condition update.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation prompt and reference conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to contain input within the generation canvas.
    ///
    /// - Throws: An error if the room or parameters are invalid or signaling submission fails.
    func updateGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) async throws

    /// Changes returned dimensions without restarting generation.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier.
    ///   - targetSize: The integer returned pixel dimensions.
    ///   - ensureActive: The configuration validity check before sending.
    ///
    /// - Throws: An error if cancelled, the room is not ready, or signaling fails.
    func changeTargetSize(
        taskID: String,
        targetSize: CGSize,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws

    /// Stops generation and clears its result stream.
    ///
    /// - Parameter taskID: The task to stop. An empty string stops the current task.
    ///
    /// - Throws: An error if the RTC stop signal cannot be sent.
    func stopGeneration(
        taskID: String
    ) async throws

    /// Sends a generation task's trajectory.
    ///
    /// - Parameters:
    ///   - taskID: The task receiving the trajectory.
    ///   - points: The trajectory points. Empty arrays are ignored.
    ///
    /// - Throws: An error if the room or task is invalid or trajectory signaling fails.
    func sendTracks(
        taskID: String,
        points: [RealtimePoint]
    ) async throws
}
