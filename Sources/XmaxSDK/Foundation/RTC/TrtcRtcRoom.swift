//
//  TrtcRtcRoom.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@preconcurrency import TXLiteAVSDK_TRTC

/// Adapts one TRTC string-ID room to common connection, signaling, and media events.
final class TrtcRtcRoom: NSObject, RtcRoom, TRTCCloudDelegate, @unchecked Sendable {

    /// The platform whose lease outlives this room.
    private let platform: TrtcRtcPlatform

    /// The server-assigned string room identifier.
    private let roomID: String

    /// Whether this room has been invalidated; protected by the platform lock.
    private(set) var isClosed = false

    /// Whether room entry has been requested.
    private var joining = false

    /// Whether native room entry was issued after any previous room exit.
    private var entryIssued = false

    /// Whether room entry has completed successfully.
    private var joined = false

    /// The listener for the current room only.
    private var listener: (@Sendable (RtcRoomEvent) -> Void)?

    /// The rate-limited signaling queue created after room entry.
    private var messages: RtcMessageQueue?

    /// The users with native video callback registrations.
    private var videoUsers: Set<String> = []

    /// Independent listener state for callbacks on native media threads.
    private let sink = TrtcRemoteFrameSink()

    /// Keeps broadcasts pending until the server-provided generation user joins the room.
    private let signalingReadiness = TrtcSignalingReadiness()

    /// Creates an unjoined room with independent callbacks.
    init(
        platform: TrtcRtcPlatform,
        roomID: String
    ) {
        self.platform = platform
        self.roomID = roomID
    }

    /// Replaces the current room event observer.
    func setEventListener(
        _ listener: (@Sendable (RtcRoomEvent) -> Void)?
    ) {
        platform.lock.withLock { self.listener = listener }
    }

    /// Starts room entry with the server-provided string-room authorization.
    func join(
        configuration: RoomJoinConfiguration
    ) throws {
        try platform.lock.withLock {
            guard !isClosed, !joining, configuration.roomID == roomID else {
                throw XmaxError(code: .invalidConfiguration, message: "TRTC room cannot be joined")
            }
            let parameters = try Self.joinParameters(configuration)
            signalingReadiness.expectUser(configuration.signalingUserID)
            joining = true
            platform.enterWhenReady { [weak self] in
                guard let self, !self.isClosed else { return }
                do {
                    try self.platform.restoreMediaForRoomEntry()
                } catch {
                    let error = XmaxError.from(error)
                    // Notify outside the platform lock: native exit callbacks run on a different
                    // thread from RTC manager cleanup, which also needs this lock.
                    self.platform.engine.delegateQueue.async { [weak self] in
                        self?.emit(.failure(error))
                    }
                    return
                }
                self.entryIssued = true
                self.platform.engine.addDelegate(self)
                self.platform.engine.setAudioFrameDelegate(self.sink)
                self.platform.engine.setDefaultStreamRecvMode(false, video: false)
                self.platform.engine.muteLocalVideo(.big, mute: true)
                self.platform.engine.muteLocalAudio(true)
                self.platform.engine.enterRoom(parameters, appScene: Self.appScene)
            }
        }
    }

    /// The realtime call scene used by the generation service's Web transport.
    static let appScene = TRTCAppScene.videoCall

    /// Converts provider-specific credentials without interpreting numeric-looking room IDs as numbers.
    static func joinParameters(
        _ configuration: RoomJoinConfiguration
    ) throws -> TRTCParams {
        guard case .trtc(let sdkAppID, let userSig, let privateMapKey) = configuration.credentials,
            sdkAppID > 0, !userSig.isEmpty, !privateMapKey.isEmpty,
            !configuration.roomID.isEmpty, !configuration.userID.isEmpty
        else {
            throw XmaxError(code: .invalidConfiguration, message: "Invalid TRTC room credentials")
        }
        let parameters = TRTCParams()
        parameters.sdkAppId = sdkAppID
        parameters.userId = configuration.userID
        parameters.userSig = userSig
        parameters.roomId = 0
        parameters.strRoomId = configuration.roomID
        parameters.privateMapKey = privateMapKey
        parameters.role = .anchor
        return parameters
    }

    /// Invalidates callbacks, cancels signaling, and leaves native media muted.
    func destroy() {
        platform.lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            joined = false
            listener = nil
            sink.close()
            messages?.close()
            messages = nil
            signalingReadiness.close()
            for userID in videoUsers {
                _ = platform.engine.setRemoteVideoRenderDelegate(
                    userID,
                    delegate: nil,
                    pixelFormat: ._NV12,
                    bufferType: .pixelBuffer
                )
            }
            videoUsers.removeAll()
            platform.engine.setAudioFrameDelegate(nil)
            platform.engine.removeDelegate(self)
            platform.publishesVideo = false
            platform.publishesAudio = false
            platform.engine.muteLocalVideo(.big, mute: true)
            platform.engine.muteLocalAudio(true)
            platform.engine.stopAllRemoteView()
            if entryIssued { platform.leaveNativeRoom() }
        }
    }

    /// Enables or pauses publication of custom video.
    func publishLocalVideo(
        _ publish: Bool
    ) throws {
        try withJoined { engine in
            platform.publishesVideo = publish
            engine.muteLocalVideo(.big, mute: !publish)
        }
    }

    /// Enables or pauses publication of the selected audio source.
    func publishLocalAudio(
        _ publish: Bool
    ) throws {
        try withJoined { engine in
            platform.publishesAudio = publish
            engine.muteLocalAudio(!publish)
        }
    }

    /// Subscribes to the main stream without attaching a native view.
    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws {
        try withJoined { engine in
            sink.setSubscription(userID: userID, video: true, subscribed: subscribe)
            if subscribe {
                engine.startRemoteView(userID, streamType: .big, view: nil)
            } else {
                engine.stopRemoteView(userID, streamType: .big)
            }
        }
    }

    /// Controls remote audio subscription and PCM callback eligibility together.
    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws {
        try withJoined { engine in
            sink.setSubscription(userID: userID, video: false, subscribed: subscribe)
            engine.muteRemoteAudio(userID, mute: !subscribe)
        }
    }

    /// Applies playback volume before remote audio is subscribed.
    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws {
        try withJoined { $0.setRemoteAudioVolume(userID, volume: Int32(max(0, min(100, volume)))) }
    }

    /// Registers custom rendering for one remote user's generated video.
    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for userID: String
    ) throws {
        try withJoined { engine in
            let result = engine.setRemoteVideoRenderDelegate(
                userID,
                delegate: listener == nil ? nil : sink,
                pixelFormat: ._NV12,
                bufferType: .pixelBuffer
            )
            guard result == 0 else {
                throw XmaxError(
                    code: .rtcError,
                    message: "TRTC video callback registration failed (\(result))"
                )
            }
            sink.setVideoListener(listener, userID: userID)
            if listener == nil { videoUsers.remove(userID) } else { videoUsers.insert(userID) }
        }
    }

    /// Registers an owned PCM listener for one remote user.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for userID: String
    ) throws {
        try withJoined { _ in sink.setAudioListener(listener, userID: userID) }
    }

    /// Enqueues signaling using TRTC command ID 1 and its fragmentation protocol.
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool,
        replacingPendingMessage key: String?
    ) throws -> Task<Void, any Error> {
        let queue = try platform.lock.withLock {
            guard joined, !isClosed, let messages else {
                throw XmaxError(code: .rtcError, message: "TRTC room is not joined")
            }
            return messages
        }
        return try queue.enqueue(
            message,
            reportFailure: reportFailure,
            replacingPendingMessage: key
        )
    }

    /// Cancels coalescible signaling that has not started sending.
    func discardPendingMessages(
        key: String?
    ) {
        platform.lock.withLock { messages }?.discardPendingMessages(key: key)
    }

    /// Waits for previously queued signaling to be submitted.
    func awaitPendingMessages() async throws {
        let queue = platform.lock.withLock { messages }
        guard let queue else { throw CancellationError() }
        try await queue.flush()
    }

    /// Converts native room entry into the common completion event.
    func onEnterRoom(
        _ result: Int
    ) {
        guard result >= 0 else {
            emit(
                .failure(XmaxError(code: .rtcError, message: "TRTC room entry failed (\(result))"))
            )
            return
        }
        let active = platform.lock.withLock {
            guard !isClosed, joining, !joined else { return false }
            joined = true
            messages = RtcMessageQueue(
                provider: .trtc,
                beforeSend: { [signalingReadiness] in
                    try await signalingReadiness.waitUntilReady()
                },
                send: { [weak self] packet in
                    guard let self else { throw CancellationError() }
                    try self.withJoined { engine in
                        guard packet.count <= 1000,
                            engine.sendCustomCmdMsg(1, data: packet, reliable: true, ordered: true)
                        else {
                            throw XmaxError(
                                code: .rtcError,
                                message: "TRTC rejected a room message"
                            )
                        }
                    }
                },
                onFailure: { [weak self] error in self?.emit(.failure(error)) }
            )
            return true
        }
        if active {
            emit(.joined)
        }
    }

    /// Reports unexpected native room exit through normal connection cleanup.
    func onExitRoom(
        _ reason: Int
    ) {
        emit(.failure(XmaxError(code: .rtcError, message: "TRTC room exited (\(reason))")))
    }

    /// Converts native runtime errors without including server credentials in diagnostics.
    func onError(
        _ errCode: TXLiteAVError,
        errMsg: String?,
        extInfo: [AnyHashable: Any]?
    ) {
        emit(.failure(XmaxError(code: .rtcError, message: "TRTC error (\(errCode.rawValue))")))
    }

    /// Forwards raw signaling to the transport-independent command receiver.
    func onRecvCustomCmdMsgUserId(
        _ userId: String,
        cmdID: Int,
        seq: UInt32,
        message: Data
    ) {
        guard cmdID == 1 else { return }
        emit(.message(userID: userId, data: message))
    }

    /// Reports availability of the main video stream used for generation.
    func onUserVideoAvailable(
        _ userId: String,
        available: Bool
    ) {
        if available { signalingReadiness.setUserPresent(userId, present: true) }
        emit(.publication(userID: userId, published: available))
    }

    /// Tracks signaling availability independently of whether the remote user is publishing video.
    func onRemoteUserEnterRoom(
        _ userId: String
    ) {
        signalingReadiness.setUserPresent(userId, present: true)
    }

    /// Invalidates publication when a remote user leaves the room.
    func onRemoteUserLeaveRoom(
        _ userId: String,
        reason: Int
    ) {
        signalingReadiness.setUserPresent(userId, present: false)
        emit(.publication(userID: userId, published: false))
    }

    /// Reports local uplink and the worst active remote-user quality.
    func onNetworkQuality(
        _ localQuality: TRTCQualityInfo,
        remoteQuality: [TRTCQualityInfo]
    ) {
        let remote = remoteQuality.map { $0.quality.rawValue }.max() ?? 0
        emit(
            .quality(
                uplink: Self.quality(localQuality.quality.rawValue),
                downlink: Self.quality(remote)
            )
        )
    }

    /// Converts measured native statistics without inventing unavailable capture or decode metrics.
    func onStatistics(
        _ statistics: TRTCStatistics
    ) {
        guard platform.lock.withLock({ !isClosed && joined }) else { return }
        for value in statistics.localStatistics where value.streamType == .big {
            let video = UplinkVideoStatistics(
                width: value.width > 0 ? Int(value.width) : nil,
                height: value.height > 0 ? Int(value.height) : nil,
                sendFrameRate: Int(value.frameRate),
                bitrateKbps: Int(value.videoBitrate),
                packetLossPercent: Int(statistics.upLoss)
            )
            emit(.uplinkVideoStatistics(video))
        }
        for value in statistics.remoteStatistics where value.streamType == .big {
            let video = DownlinkVideoStatistics(
                userID: value.userId,
                width: value.width > 0 ? Int(value.width) : nil,
                height: value.height > 0 ? Int(value.height) : nil,
                renderFrameRate: Int(value.frameRate),
                bitrateKbps: Int(value.videoBitrate),
                packetLossPercent: Int(value.videoPacketLoss),
                endToEndDelayMs: Int(value.point2PointDelay)
            )
            emit(.downlinkVideoStatistics(video))
        }
    }

    /// Executes an operation only while this room owns the native connection.
    private func withJoined<T>(
        _ operation: (TRTCCloud) throws -> T
    ) throws -> T {
        try platform.lock.withLock {
            guard joined, !isClosed else {
                throw XmaxError(code: .rtcError, message: "TRTC room is not joined")
            }
            return try operation(platform.engine)
        }
    }

    /// Snapshots the observer before delivery to avoid lock inversion with RTC manager cleanup.
    private func emit(
        _ event: RtcRoomEvent
    ) {
        let callback = platform.lock.withLock { isClosed ? nil : listener }
        callback?(event)
    }

    /// Maps TRTC's six network levels to the common quality scale.
    private static func quality(
        _ value: Int
    ) -> RtcQualityLevel {
        switch value {
        case 1: .excellent
        case 2: .good
        case 3: .poor
        case 4: .bad
        case 5: .veryBad
        case 6: .down
        default: .unknown
        }
    }
}
