//
//  RealtimeSessionConnection.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The RTC credentials for a realtime session.
struct RealtimeSessionConnection: Equatable, Sendable {

    /// The server-assigned RTC room identifier.
    let roomID: String

    /// The local RTC user identifier.
    let userID: String

    /// The provider-specific RTC credentials.
    let credentials: RtcCredentials

    /// The remote user providing generated media.
    let botName: String?

    /// Creates a session connection with provider-specific credentials.
    init(
        roomID: String,
        userID: String,
        credentials: RtcCredentials,
        botName: String?
    ) {
        self.roomID = roomID
        self.userID = userID
        self.credentials = credentials
        self.botName = botName
    }

    /// Creates an Agora session connection.
    init(
        roomID: String,
        userID: String,
        token: String,
        botName: String?
    ) {
        self.init(roomID: roomID, userID: userID, credentials: .agora(token: token), botName: botName)
    }
}

/// A handler for realtime session heartbeat failure.
typealias RealtimeSessionHeartbeatFailureHandler =
    @Sendable (
        _ sessionID: String,
        _ error: XmaxError
    ) async -> Void
