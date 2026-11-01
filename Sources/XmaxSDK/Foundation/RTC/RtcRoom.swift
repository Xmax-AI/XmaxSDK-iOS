//
//  RtcRoom.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A vendor-independent RTC room event.
enum RtcRoomEvent: Sendable {

    /// The RTC room connection succeeded.
    case joined

    /// A remote user's video publication changed.
    case publication(userID: String, published: Bool)

    /// A remote user sent an unparsed signaling packet.
    case message(userID: String, data: Data)

    /// The room connection or media transport failed.
    case failure(XmaxError)

    /// Uplink and downlink network quality changed.
    case quality(uplink: RtcQualityLevel, downlink: RtcQualityLevel)

    /// Uplink video statistics were updated.
    case uplinkVideoStatistics(UplinkVideoStatistics)

    /// Downlink video statistics were updated.
    case downlinkVideoStatistics(DownlinkVideoStatistics)

    /// Local encoding performance or format changed.
    case performance(limited: Bool, width: Int, height: Int, frameRate: Int)
}

/// A vendor-independent room serving one connection.
protocol RtcRoom: AnyObject, Sendable {

    /// Sets the room event listener.
    ///
    /// - Parameter listener: The event handler, or `nil` to remove it.
    func setEventListener(
        _ listener: (@Sendable (RtcRoomEvent) -> Void)?
    )

    /// Begins room join; completion is reported by the joined event.
    ///
    /// - Parameter configuration: The room, user account, and token.
    ///
    /// - Throws: An error if the join request fails immediately.
    func join(
        configuration: RoomJoinConfiguration
    ) throws

    /// Leaves the room and clears callbacks and queued signaling. Repeated calls are safe.
    func destroy()

    /// Changes local video publication.
    ///
    /// - Parameter publish: Whether to publish external video.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalVideo(
        _ publish: Bool
    ) throws

    /// Changes local audio publication.
    ///
    /// - Parameter publish: Whether to publish the current audio source.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalAudio(
        _ publish: Bool
    ) throws

    /// Changes a remote video subscription.
    ///
    /// - Parameters:
    ///   - userID: The server-assigned RTC account.
    ///   - subscribe: Whether to subscribe to video.
    ///
    /// - Throws: An error if user mapping or subscription fails.
    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws

    /// Changes a remote audio subscription.
    ///
    /// - Parameters:
    ///   - userID: The server-assigned RTC account.
    ///   - subscribe: Whether to subscribe to audio.
    ///
    /// - Throws: An error if user mapping or subscription fails.
    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws

    /// Sets remote audio playback volume.
    ///
    /// - Parameters:
    ///   - volume: The volume, from 0 to 100.
    ///   - userID: The RTC user account.
    ///
    /// - Throws: An error if user mapping or volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws

    /// Sets a decoded remote frame listener.
    ///
    /// - Parameters:
    ///   - listener: The frame handler, or `nil` to remove it.
    ///   - userID: The RTC user account.
    ///
    /// - Throws: An error if the user cannot be resolved.
    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for userID: String
    )
        throws

    /// Sets a listener for one remote user's owned PCM before remote-user mixing.
    ///
    /// - Parameters:
    ///   - listener: The audio handler, or `nil` to remove it.
    ///   - userID: The remote RTC user account.
    ///
    /// - Throws: An error if the room or remote account is unavailable.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for userID: String
    ) throws

    /// Enqueues room signaling.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failure is fatal. When `false`, failure is
    ///     logged and thrown to the waiting caller.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///
    /// - Throws: An error if the message is invalid or the queue is unavailable.
    ///
    /// - Returns: The message's send task.
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

    /// Waits for previously queued signaling to be submitted to RTC.
    ///
    /// - Throws: An error if sending fails, the room closes, or the call is cancelled.
    func awaitPendingMessages() async throws
}

extension RtcRoom {

    /// Enqueues signaling with asynchronous failure reporting enabled.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failures are reported as room failures.
    ///
    /// - Returns: The message's send task.
    ///
    /// - Throws: An error if signaling is invalid or the send queue is unavailable.
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
