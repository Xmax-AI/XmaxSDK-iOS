//
//  AgoraRtcRoom.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit
import Foundation

/// An Agora connection adapter for users, media, and data-stream signaling.
final class AgoraRtcRoom: RtcRoom, @unchecked Sendable {

    // MARK: - Dependencies

    /// The owning Agora platform and shared engine.
    private let platform: AgoraRtcPlatform

    /// The Agora channel name.
    private let roomID: String

    /// The room's Agora connection.
    let connection = AgoraRtcConnection()

    // MARK: - State

    /// The bridge from Agora callbacks to room events.
    private var bridge: RtcRoomEventBridge?

    /// The decoded frame receiver.
    private var videoSink: RtcRemoteVideoSink?

    /// The room-scoped remote PCM observer, installed before joining the room.
    private var audioSink: RtcRemoteAudioSink?

    /// The listener for connection, publication, and quality events.
    private var listener: (@Sendable (RtcRoomEvent) -> Void)?

    /// The mapping from Agora numeric UIDs to application user accounts.
    private var accounts: [UInt: String] = [:]

    /// The video publication state of remote users.
    private var publications: [UInt: Bool] = [:]

    /// Independent callback snapshots; native media threads never acquire the engine lock.
    private let mediaListeners: RtcRemoteFrameListeners

    /// The signaling data stream identifier.
    private var dataStreamID = 0

    /// The room's signaling queue.
    private var sender: RtcMessageQueue?

    /// The local account, protected by `platform.lock`.
    private var account: String?

    /// Whether room join has completed.
    private(set) var isJoined = false

    /// Whether the room is closed to further operations.
    private(set) var isClosed = false

    /// Creates an Agora room for one connection.
    ///
    /// - Parameters:
    ///   - platform: The platform adapter owning the Agora engine.
    ///   - roomID: The RTC room identifier.
    init(
        platform: AgoraRtcPlatform,
        roomID: String
    ) {
        self.platform = platform
        self.roomID = roomID
        mediaListeners = RtcRemoteFrameListeners(roomID: roomID)
        connection.channelId = roomID
    }

    /// Sets the room event listener.
    ///
    /// - Parameter listener: The event handler, or `nil` to remove it.
    func setEventListener(
        _ listener: (@Sendable (RtcRoomEvent) -> Void)?
    ) {
        platform.lock.withLock {
            self.listener = isClosed ? nil : listener
        }
    }

    /// Begins room join; completion is reported by the joined event.
    ///
    /// - Parameter configuration: The room, user account, and token.
    ///
    /// - Throws: An error if the join request fails immediately.
    func join(
        configuration: RoomJoinConfiguration
    ) throws {
        try platform.lock.withLock {
            guard case .agora(let token) = configuration.credentials else {
                throw XmaxError(code: .invalidConfiguration, message: "Agora credentials required")
            }
            guard !isClosed, account == nil, configuration.roomID == roomID else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC room cannot be joined"
                )
            }
            account = configuration.userID
            let bridge = RtcRoomEventBridge { [weak self] event in
                self?.handle(event)
            }
            self.bridge = bridge

            let mediaListeners = self.mediaListeners
            let sink = RtcRemoteVideoSink { uid, channelID, frame in
                let callback = mediaListeners.videoListener(
                    for: uid,
                    channelID: channelID
                )
                callback?(frame)
            }

            videoSink = sink
            guard platform.engine.setVideoFrameDelegate(sink) else {
                throw XmaxError(
                    code: .rtcError,
                    message: "Failed to register RTC video frame observer"
                )
            }

            let audioSink = RtcRemoteAudioSink { uid, channelID in
                mediaListeners.audioListener(
                    for: uid,
                    channelID: channelID
                )
            }

            self.audioSink = audioSink
            let preMixFormatResult = platform.engine.setPlaybackAudioFrameBeforeMixingParametersWithSampleRate(
                48_000,
                channel: 1,
                samplesPerCall: 480
            )
            try AgoraRtcPlatform.checkResult(
                preMixFormatResult,
                operation: "configureRemoteAudioFrames"
            )

            let observerRegistered = platform.engine.setAudioFrameDelegate(audioSink)
            guard observerRegistered else {
                throw XmaxError(
                    code: .rtcError,
                    message: "Failed to register RTC audio frame observer"
                )
            }

            let options = AgoraRtcChannelMediaOptions()
            options.channelProfile = .liveBroadcasting
            options.clientRoleType = .broadcaster
            options.publishCameraTrack = false
            options.publishCustomVideoTrack = false
            options.publishMicrophoneTrack = false
            options.publishCustomAudioTrack = false
            options.autoSubscribeAudio = false
            options.autoSubscribeVideo = false

            try AgoraRtcPlatform.checkResult(
                platform.engine.joinChannelEx(
                    byToken: token,
                    channelId: roomID,
                    userAccount: configuration.userID,
                    delegate: bridge,
                    mediaOptions: options,
                    joinSuccess: nil
                ),
                operation: "joinChannelEx"
            )
        }
    }

    /// Leaves the room and clears callbacks and queued signaling. Repeated calls are safe.
    func destroy() {
        platform.lock.withLock {
            guard !isClosed else {
                return
            }

            isClosed = true
            isJoined = false
            listener = nil
            sender?.close()
            sender = nil
            // Invalidate before unregistering: Agora may wait for an in-flight media callback.
            mediaListeners.close()
            accounts.removeAll()
            publications.removeAll()

            if let account {
                platform.engine.setVideoFrameDelegate(nil)
                platform.engine.setAudioFrameDelegate(nil)
                _ = platform.engine.leaveChannelEx(
                    roomID,
                    userAccount: account,
                    leaveChannelBlock: nil
                )
            }

            bridge = nil
            videoSink = nil
            audioSink = nil
        }
    }

    /// Changes local video publication.
    ///
    /// - Parameter publish: Whether to publish external video.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalVideo(
        _ publish: Bool
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            let options = AgoraRtcChannelMediaOptions()
            options.publishCameraTrack = false
            options.publishCustomVideoTrack = publish
            options.customVideoTrackId = 0
            try update(
                options,
                operation: "publishLocalVideo"
            )

            if publish {
                try platform.reapplyVideoConfiguration()
            }
        }
    }

    /// Changes local audio publication.
    ///
    /// - Parameter publish: Whether to publish the current audio source.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalAudio(
        _ publish: Bool
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            let options = AgoraRtcChannelMediaOptions()
            options.publishMicrophoneTrack = publish && platform.audioTrackID == nil
            options.publishCustomAudioTrack = publish && platform.audioTrackID != nil
            if let audioTrackID = platform.audioTrackID {
                options.publishCustomAudioTrackId = audioTrackID
            }
            try update(
                options,
                operation: "publishLocalAudio"
            )
        }
    }

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
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            try AgoraRtcPlatform.checkResult(
                platform.engine.muteRemoteVideoStreamEx(
                    try resolveUID(userID),
                    mute: !subscribe,
                    connection: connection
                ),
                operation: "subscribeRemoteVideo"
            )
        }
    }

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
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            let uid = try resolveUID(userID)
            try AgoraRtcPlatform.checkResult(
                platform.engine.muteRemoteAudioStreamEx(
                    uid,
                    mute: !subscribe,
                    connection: connection
                ),
                operation: "subscribeRemoteAudio"
            )
        }
    }

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
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            try AgoraRtcPlatform.checkResult(
                platform.engine.adjustUserPlaybackSignalVolumeEx(
                    try resolveUID(userID),
                    volume: volume,
                    connection: connection
                ),
                operation: "setRemoteAudioVolume"
            )
        }
    }

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
    {
        try platform.lock.withLock {
            try requireJoined()
            let uid = try resolveUID(userID)
            mediaListeners.setVideoListener(
                listener,
                for: uid
            )
        }
    }

    /// Sets a PCM listener for the resolved remote user without changing playback volume.
    ///
    /// - Parameters:
    ///   - listener: The owned audio handler, or `nil` to remove it.
    ///   - userID: The remote RTC user account.
    ///
    /// - Throws: An error if the room or remote account is unavailable.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for userID: String
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            let uid = try resolveUID(userID)
            mediaListeners.setAudioListener(
                listener,
                for: uid
            )
        }
    }

    /// Enqueues room signaling.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failure is fatal. When `false`, failure is
    ///     logged and thrown to the waiting caller.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///
    /// - Returns: The message's send task.
    ///
    /// - Throws: An error if the message is invalid or the queue is unavailable.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool = true,
        replacingPendingMessage key: String? = nil
    ) throws -> Task<Void, any Error> {
        try platform.lock.withLock {
            try requireJoined()
            guard let sender else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC signaling is unavailable"
                )
            }

            return try sender.enqueue(
                message,
                reportFailure: reportFailure,
                replacingPendingMessage: key
            )
        }
    }

    /// Drops coalescible messages that have not started sending.
    ///
    /// - Parameter key: The coalescing key, or `nil` for all coalescible messages.
    func discardPendingMessages(
        key: String?
    ) {
        platform.lock.withLock {
            sender?.discardPendingMessages(key: key)
        }
    }

    /// Waits for previously queued signaling to be submitted to RTC.
    ///
    /// - Throws: An error if sending fails, the room closes, or the call is cancelled.
    func awaitPendingMessages() async throws {
        let sender = try platform.lock.withLock {
            try requireJoined()
            return sender
        }
        try await sender?.flush()
    }
}

private extension AgoraRtcRoom {

    /// Converts a platform event and notifies the room listener outside the platform lock.
    ///
    /// - Parameter event: The Agora connection event.
    func handle(
        _ event: RtcRoomEventBridge.Event
    ) {
        let events: [RtcRoomEvent] = platform.lock.withLock {
            guard !isClosed else {
                return []
            }

            switch event {
            case .joined(let uid):
                guard !isJoined else {
                    return []
                }

                do {
                    try prepareJoinedRoom(uid: uid)
                    return [.joined]
                        + publications.compactMap { uid, published in
                            publicationEvent(
                                uid: uid,
                                published: published
                            )
                        }
                } catch {
                    return [.failure(XmaxError.from(error))]
                }
            case .account(
                let uid,
                let account
            ):
                accounts[uid] = account
                return publicationEvents(uid: uid)
            case .userJoined(let uid):
                resolveAccount(uid: uid)
                return publicationEvents(uid: uid)
            case .message(let uid, let data):
                resolveAccount(uid: uid)
                guard let account = accounts[uid] else { return [] }
                return [.message(userID: account, data: data)]
            case .publication(
                let uid,
                let published
            ):
                publications[uid] = published
                resolveAccount(uid: uid)
                return publicationEvents(uid: uid)
            case .failure(let message):
                return [
                    .failure(
                        XmaxError(
                            code: .rtcError,
                            message: message
                        )
                    )
                ]
            case .quality(
                let up,
                let down
            ):
                return [
                    .quality(
                        uplink: RtcQualityConverter.convertLevel(up),
                        downlink: RtcQualityConverter.convertLevel(down)
                    )
                ]
            case .localStats(let stats):
                let statistics = RtcQualityConverter.uplinkVideoStatistics(stats)
                RtcStatsLogger.logUplinkVideoStatistics(statistics)
                let adaptation = stats.qualityAdaptIndication.rawValue
                let events: [RtcRoomEvent] = [.uplinkVideoStatistics(statistics)]
                guard adaptation == 1 || adaptation == 2 else {
                    return events
                }

                return events + [
                    .performance(
                        limited: adaptation == 2,
                        width: stats.encodedFrameWidth,
                        height: stats.encodedFrameHeight,
                        frameRate: stats.encoderOutputFrameRate
                    )
                ]
            case .remoteStats(let stats):
                resolveAccount(uid: stats.uid)
                guard let account = accounts[stats.uid] else {
                    return []
                }
                let statistics = RtcQualityConverter.downlinkVideoStatistics(
                    userID: account,
                    stats
                )
                RtcStatsLogger.logDownlinkVideoStatistics(statistics)
                return [.downlinkVideoStatistics(statistics)]
            }
        }

        // Notify lifecycle handlers outside the platform lock to avoid lock-order inversion.
        for event in events {
            emit(event)
        }
    }

    /// Initializes the room's ordered signaling channel.
    ///
    /// - Parameter uid: The local numeric UID.
    ///
    /// - Throws: An error if the signaling channel cannot be created.
    func prepareJoinedRoom(
        uid: UInt
    ) throws {
        connection.localUid = uid

        let config = AgoraDataStreamConfig()
        config.ordered = true
        config.syncWithAudio = false
        try AgoraRtcPlatform.checkResult(
            platform.engine.createDataStreamEx(
                &dataStreamID,
                config: config,
                connection: connection
            ),
            operation: "createDataStreamEx"
        )

        sender = RtcMessageQueue(
            send: { [weak self] data in
                guard let self else {
                    throw CancellationError()
                }

                try platform.lock.withLock {
                    try requireJoined()
                    try AgoraRtcPlatform.checkResult(
                        platform.engine.sendStreamMessageEx(
                            dataStreamID,
                            data: data,
                            connection: connection
                        ),
                        operation: "sendStreamMessageEx"
                    )
                }
            },
            onFailure: { [weak self] error in
                self?.emit(.failure(error))
            }
        )

        isJoined = true
    }

    /// Delivers an event to the active room listener.
    ///
    /// - Parameter event: The room event.
    func emit(
        _ event: RtcRoomEvent
    ) {
        let callback = platform.lock.withLock {
            isClosed ? nil : listener
        }
        callback?(event)
    }

    /// Resolves the current video publication events for a known user.
    ///
    /// - Parameter uid: The remote numeric UID.
    ///
    /// - Returns: The publication events, or an empty array if account or state is unavailable.
    func publicationEvents(
        uid: UInt
    ) -> [RtcRoomEvent] {
        guard let published = publications[uid],
            let event = publicationEvent(
                uid: uid,
                published: published
            )
        else {
            return []
        }
        return [event]
    }

    /// Converts numeric user publication state to an account event.
    ///
    /// - Parameters:
    ///   - uid: The remote numeric UID.
    ///   - published: Whether video is published.
    ///
    /// - Returns: A publication event if the account is available and the room is joined; otherwise
    ///   `nil`.
    func publicationEvent(
        uid: UInt,
        published: Bool
    ) -> RtcRoomEvent? {
        guard isJoined, let account = accounts[uid] else {
            return nil
        }
        return .publication(
            userID: account,
            published: published
        )
    }

    /// Retrieves an uncached user account from the platform.
    ///
    /// - Parameter uid: The remote numeric UID.
    func resolveAccount(
        uid: UInt
    ) {
        guard accounts[uid] == nil else {
            return
        }
        accounts[uid] =
            platform.engine.getUserInfo(
                byUidEx: uid,
                connection: connection,
                withError: nil
            )?.userAccount
    }

    /// Resolves an account's numeric UID.
    ///
    /// - Parameter account: The remote user account.
    ///
    /// - Returns: The account's numeric UID.
    ///
    /// - Throws: An error if the account mapping is unavailable.
    func resolveUID(
        _ account: String
    ) throws -> UInt {
        if let uid = accounts.first(where: {
            $0.value == account
        })?.key {
            return uid
        }

        if let info = platform.engine.getUserInfo(
            byUserAccountEx: account,
            connection: connection,
            withError: nil
        ) {
            accounts[info.uid] = account
            return info.uid
        }

        throw XmaxError(
            code: .rtcError,
            message: "RTC user account is not available: \(account)"
        )
    }

    /// Verifies that the room is open and joined.
    ///
    /// - Throws: An error if the room is disconnected or closed.
    func requireJoined() throws {
        guard !isClosed, isJoined else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC room is not joined"
            )
        }
    }

    /// Updates connection media options.
    ///
    /// - Parameters:
    ///   - options: The publication or subscription options.
    ///   - operation: The operation name for the error message.
    ///
    /// - Throws: An error if the platform rejects the update.
    func update(
        _ options: AgoraRtcChannelMediaOptions,
        operation: String
    ) throws {
        try AgoraRtcPlatform.checkResult(
            platform.engine.updateChannelEx(
                with: options,
                connection: connection
            ),
            operation: operation
        )
    }
}

/// Stores native callback snapshots separately from locks held across Agora engine calls.
///
/// The lock protects dictionaries only. Resolve a callback here, then invoke it after returning;
/// never call the engine or application code under this lock. An in-flight snapshot may finish
/// after close; downstream room/stream lifetime guards reject obsolete output.
final class RtcRemoteFrameListeners: @unchecked Sendable {

    /// The lock protecting listener bindings and the closed state.
    private let lock = NSLock()

    /// The room identifier accepted by listener lookups.
    private let roomID: String

    /// Whether this registry has stopped accepting listener changes and lookups.
    private var closed = false

    /// The video callbacks keyed by remote user identifier.
    private var video: [UInt: RtcRemoteVideoFrameListener] = [:]

    /// The audio callbacks keyed by remote user identifier.
    private var audio: [UInt: RtcRemoteAudioFrameListener] = [:]

    /// Creates a listener registry for a room.
    init(
        roomID: String
    ) {
        self.roomID = roomID
    }

    /// Sets or removes a remote user's video callback while the registry is open.
    ///
    /// - Parameters:
    ///   - listener: The video callback, or `nil` to remove it.
    ///   - uid: The remote user identifier.
    func setVideoListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for uid: UInt
    ) {
        lock.withLock {
            guard !closed else {
                return
            }

            video[uid] = listener
        }
    }

    /// Sets or removes a remote user's audio callback while the registry is open.
    ///
    /// - Parameters:
    ///   - listener: The audio callback, or `nil` to remove it.
    ///   - uid: The remote user identifier.
    func setAudioListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for uid: UInt
    ) {
        lock.withLock {
            guard !closed else {
                return
            }

            audio[uid] = listener
        }
    }

    /// Resolves a video callback for an open, matching room.
    ///
    /// - Parameters:
    ///   - uid: The remote user identifier.
    ///   - channelID: The room identifier reported by the native callback.
    ///
    /// - Returns: The registered video callback, or `nil` if the binding is unavailable.
    func videoListener(
        for uid: UInt,
        channelID: String
    ) -> RtcRemoteVideoFrameListener? {
        lock.withLock { !closed && channelID == roomID ? video[uid] : nil }
    }

    /// Resolves an audio callback for an open, matching room.
    ///
    /// - Parameters:
    ///   - uid: The remote user identifier.
    ///   - channelID: The room identifier reported by the native callback.
    ///
    /// - Returns: The registered audio callback, or `nil` if the binding is unavailable.
    func audioListener(
        for uid: UInt,
        channelID: String
    ) -> RtcRemoteAudioFrameListener? {
        lock.withLock { !closed && channelID == roomID ? audio[uid] : nil }
    }

    /// Rejects future lookups and releases all registered callbacks.
    func close() {
        lock.withLock {
            closed = true
            video.removeAll()
            audio.removeAll()
        }
    }
}
