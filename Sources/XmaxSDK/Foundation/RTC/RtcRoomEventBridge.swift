//
//  RtcRoomEventBridge.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@preconcurrency import AgoraRtcKit

/// Forwards Agora connection callbacks to the RTC manager.
final class RtcRoomEventBridge: NSObject, AgoraRtcEngineDelegate {

    /// The user, media, and quality events of an Agora connection.
    enum Event {

        /// The local user joined with a numeric UID.
        case joined(UInt)

        /// A numeric UID-to-account mapping changed.
        case account(UInt, String)

        /// A remote user's video publication changed.
        case publication(UInt, Bool)

        /// A remote user joined.
        case userJoined(UInt)

        /// An owned signaling packet from a numeric remote user.
        case message(UInt, Data)

        /// An Agora room error and description.
        case failure(String)

        /// Uplink and downlink quality ratings changed.
        case quality(AgoraNetworkQuality, AgoraNetworkQuality)

        /// Local video statistics were updated.
        case localStats(AgoraRtcLocalVideoStats)

        /// Remote video statistics were updated.
        case remoteStats(AgoraRtcRemoteVideoStats)
    }

    /// The converted event handler.
    private let handler: @Sendable (Event) -> Void

    /// Forwards a native data-stream message without interpreting its business protocol.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        receiveStreamMessageFromUid uid: UInt,
        streamId: Int,
        data: Data
    ) {
        handler(.message(uid, data))
    }

    /// Creates a room event bridge.
    init(
        handler: @escaping @Sendable (Event) -> Void
    ) {
        self.handler = handler
    }

    /// Forwards a successful local room join.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - channel: The joined channel identifier.
    ///   - uid: The local numeric UID.
    ///   - elapsed: The elapsed join time, in milliseconds.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didJoinChannel channel: String,
        withUid uid: UInt,
        elapsed: Int
    ) {
        handler(.joined(uid))
    }

    /// Forwards a remote user's UID-to-account mapping.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - uid: The remote numeric UID.
    ///   - userInfo: The user account information.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didUserInfoUpdatedWithUserId uid: UInt,
        userInfo: AgoraUserInfo
    ) {
        guard let account = userInfo.userAccount, !account.isEmpty else {
            return
        }
        handler(
            .account(
                uid,
                account
            )
        )
    }

    /// Forwards a remote user join.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - uid: The joined remote numeric UID.
    ///   - elapsed: The elapsed join notification time, in milliseconds.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didJoinedOfUid uid: UInt,
        elapsed: Int
    ) {
        handler(.userJoined(uid))
    }

    /// Reports video unpublication when a remote user leaves.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - uid: The departing remote numeric UID.
    ///   - reason: The user's offline reason.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didOfflineOfUid uid: UInt,
        reason: AgoraUserOfflineReason
    ) {
        handler(
            .publication(
                uid,
                false
            )
        )
    }

    /// Maps remote video muting to publication state.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - muted: Whether remote video is muted.
    ///   - uid: The remote numeric UID.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didVideoMuted muted: Bool,
        byUid uid: UInt
    ) {
        handler(
            .publication(
                uid,
                !muted
            )
        )
    }

    /// Maps remote video enablement to publication state.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - enabled: Whether remote video is enabled.
    ///   - uid: The remote numeric UID.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didVideoEnabled enabled: Bool,
        byUid uid: UInt
    ) {
        handler(
            .publication(
                uid,
                enabled
            )
        )
    }

    /// Maps remote video enablement to publication state.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - enabled: Whether remote video is enabled.
    ///   - uid: The remote numeric UID.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didLocalVideoEnabled enabled: Bool,
        byUid uid: UInt
    ) {
        handler(
            .publication(
                uid,
                enabled
            )
        )
    }

    /// Resolves video publication from remote user state flags.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - uid: The remote numeric UID.
    ///   - state: The remote user state flags.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        remoteUserStateChangedOfUid uid: UInt,
        state: UInt
    ) {
        // Agora `USER_STATE` flags allow publication detection before subscription.
        let muteVideo: UInt = 1 << 1
        let enableVideo: UInt = 1 << 4
        let enableLocalVideo: UInt = 1 << 8
        let published =
            state & muteVideo == 0 && state & enableVideo != 0 && state & enableLocalVideo != 0
        handler(
            .publication(
                uid,
                published
            )
        )
    }

    /// Maps remote video reception to publication events.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - uid: The remote numeric UID.
    ///   - state: The video reception state.
    ///   - reason: The state change reason.
    ///   - elapsed: The elapsed state change time, in milliseconds.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        remoteVideoStateChangedOfUid uid: UInt,
        state: AgoraVideoRemoteState,
        reason: AgoraVideoRemoteReason,
        elapsed: Int
    ) {
        if state == .starting || state == .decoding {
            handler(
                .publication(
                    uid,
                    true
                )
            )
        } else if reason == .remoteMuted || reason == .remoteOffline {
            handler(
                .publication(
                    uid,
                    false
                )
            )
        }
    }

    /// Forwards an RTC connection failure.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - state: The connection state.
    ///   - reason: The connection state change reason.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        connectionChangedTo state: AgoraConnectionState,
        reason: AgoraConnectionChangedReason
    ) {
        if state == .failed {
            handler(.failure("Agora connection failed: \(reason.rawValue)"))
        }
    }

    /// Reports room failure when the token expires.
    ///
    /// - Parameter engine: The engine requesting a new token.
    func rtcEngineRequestToken(
        _ engine: AgoraRtcEngineKit
    ) {
        handler(.failure("Agora RTC token expired"))
    }

    /// Logs an Agora engine error.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - errorCode: The Agora error code.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didOccurError errorCode: AgoraErrorCode
    ) {
        XmaxLogger.rtc.error(
            message: "声网 RTC 错误 (Agora RTC Error)\n└─ \(errorCode.rawValue)"
        )
    }

    /// Forwards local uplink and downlink quality.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - uid: The sampled UID; zero identifies the local user.
    ///   - txQuality: The uplink quality.
    ///   - rxQuality: The downlink quality.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        networkQuality uid: UInt,
        txQuality: AgoraNetworkQuality,
        rxQuality: AgoraNetworkQuality
    ) {
        if uid == 0 {
            handler(
                .quality(
                    txQuality,
                    rxQuality
                )
            )
        }
    }

    /// Forwards local uplink video statistics.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - stats: The local video statistics.
    ///   - sourceType: The video source being measured.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        localVideoStats stats: AgoraRtcLocalVideoStats,
        sourceType: AgoraVideoSourceType
    ) {
        handler(.localStats(stats))
    }

    /// Forwards remote downlink video statistics.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine sending the callback.
    ///   - stats: The remote video statistics.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        remoteVideoStats stats: AgoraRtcRemoteVideoStats
    ) {
        handler(.remoteStats(stats))
    }
}
