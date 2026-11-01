//
//  RtcManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// An interface for RTC engines, rooms, media, and remote frames.
protocol RtcManaging: Sendable {

    /// Sets a room-scoped raw signaling listener; callbacks may arrive on native RTC threads.
    func setRoomMessageListener(
        _ listener: (@Sendable (String, Data) -> Void)?
    )

    /// Acquires an exclusive engine lease and initializes RTC.
    ///
    /// - Throws: An error if lease acquisition is cancelled or initialization fails.
    func initialize() async throws

    /// Destroys the RTC engine and releases resources.
    func destroy() async

    /// Applies the uplink encoder configuration.
    ///
    /// - Parameter configuration: The dimensions, frame rate, bitrate, and encoding preference.
    ///
    /// - Throws: An error if the engine rejects the configuration.
    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws

    /// Switches to microphone input and starts capture.
    ///
    /// - Throws: An error if source switching or capture fails.
    func startAudioCapture() throws

    /// Stops microphone capture.
    ///
    /// - Throws: An error if the engine cannot stop capture.
    func stopAudioCapture() throws

    /// Enables external video input.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws

    /// Enables external PCM input.
    ///
    /// - Throws: An error if the external audio track cannot be created.
    func startExternalAudioSource() throws

    /// Stops external PCM input and releases its track.
    ///
    /// - Throws: An error if the audio track cannot be released.
    func stopExternalAudioSource() throws

    /// Updates uplink video mirroring.
    ///
    /// - Parameter position: The current camera position.
    ///
    /// - Throws: An error if encoder mirroring cannot be configured.
    func configureLocalVideoMirror(
        for position: CameraPosition
    ) throws

    /// Pushes an external video frame.
    ///
    /// - Parameter frame: The SDK video frame.
    ///
    /// - Throws: An error if the frame format or data is invalid.
    func pushExternalVideoFrame(
        _ frame: VideoFrame
    ) throws

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: A timestamped 10 ms PCM frame.
    ///
    /// - Throws: An error if the frame format or data is invalid.
    func pushExternalAudioFrame(
        _ frame: AudioFrame
    ) throws

    /// Joins an RTC room and waits for connection.
    ///
    /// - Parameter configuration: The room, user identifier, and token.
    ///
    /// - Throws: An error if the engine is unavailable, join fails or times out, or the call is
    ///   cancelled.
    func joinRoom(
        configuration: RoomJoinConfiguration
    ) async throws

    /// Leaves the active RTC room.
    func leaveRoom() async

    /// Publishes local video.
    ///
    /// - Throws: An error if the room is unavailable or publication fails.
    func publishLocalVideo() throws

    /// Stops local video publication.
    ///
    /// - Throws: An error if the room is unavailable or unpublishing fails.
    func unpublishLocalVideo() throws

    /// Publishes local audio.
    ///
    /// - Throws: An error if the room is unavailable or audio publication fails.
    func publishLocalAudio() throws

    /// Stops local audio publication.
    ///
    /// - Throws: An error if the room is unavailable or audio unpublishing fails.
    func unpublishLocalAudio() throws

    /// Changes a remote user's video subscription.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to video.
    ///
    /// - Throws: An error if the room is unavailable, the user cannot be resolved, or subscription
    ///   fails.
    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws

    /// Changes a remote user's audio subscription.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to audio.
    ///
    /// - Throws: An error if the room is unavailable, the user cannot be resolved, or subscription
    ///   fails.
    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws

    /// Sets a remote user's playback volume.
    ///
    /// - Parameters:
    ///   - volume: The playback volume, from 0 to 100.
    ///   - userID: The remote RTC user identifier.
    ///
    /// - Throws: An error if the room is unavailable or volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws

    /// Sets a decoded frame listener for a remote stream.
    ///
    /// - Parameters:
    ///   - listener: The decoded frame handler, or `nil` to remove it.
    ///   - stream: The remote stream to observe.
    ///
    /// - Throws: An error if the room is unavailable or the listener cannot be configured.
    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for stream: RemoteStream
    ) throws

    /// Sets a current-room listener for one remote user's owned PCM.
    ///
    /// - Parameters:
    ///   - listener: The audio handler, or `nil` to remove it.
    ///   - stream: The remote result stream.
    ///
    /// - Throws: An error if the room or remote user is unavailable.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for stream: RemoteStream
    ) throws

    /// Sends a message to the active RTC room.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failures are reported as room failures.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///
    /// - Returns: The task for awaiting this message's send result.
    ///
    /// - Throws: An error if enqueueing fails.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool,
        replacingPendingMessage key: String?
    ) throws -> Task<Void, any Error>

    /// Drops coalescible messages that have not started sending.
    ///
    /// - Parameter key: The coalescing key, or `nil` for all coalescible messages.
    func discardPendingMessages(
        key: String?
    )

    /// Waits for queued room signaling to finish.
    ///
    /// - Throws: An error if the room is unavailable, sending fails, or waiting is cancelled.
    func awaitPendingMessages() async throws

    /// Sets the RTC connection and media event listener.
    ///
    /// - Parameter listener: The event listener, or `nil` to remove it.
    func setEventListener(
        _ listener: (any RtcEventListener)?
    )

    /// Sets the RTC network and media quality listener.
    ///
    /// - Parameter listener: The quality listener, or `nil` to remove it.
    func setQualityListener(
        _ listener: (any RtcQualityListener)?
    )
}

extension RtcManaging {

    /// Allows media-only implementations to omit incoming signaling.
    func setRoomMessageListener(
        _ listener: (@Sendable (String, Data) -> Void)?
    ) {}

    /// Enqueues signaling with asynchronous failure reporting enabled.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failures are reported as room failures.
    ///
    /// - Returns: The message's send task.
    ///
    /// - Throws: An error if signaling cannot be enqueued.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool = true
    ) throws -> Task<Void, any Error> {
        try sendRoomMessage(
            message,
            reportFailure: reportFailure,
            replacingPendingMessage: nil
        )
    }
}
