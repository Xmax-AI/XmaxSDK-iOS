//
//  RoomJoinConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The credentials for joining an RTC room.
struct RoomJoinConfiguration: Equatable, Sendable {

    /// The RTC room identifier to join.
    let roomID: String

    /// The local RTC user identifier.
    let userID: String

    /// The provider-specific room authentication.
    let credentials: RtcCredentials

    /// The remote signaling recipient, whose presence is required before TRTC broadcasts messages.
    let signalingUserID: String?

    /// Creates room parameters with provider-specific credentials.
    init(
        roomID: String,
        userID: String,
        credentials: RtcCredentials,
        signalingUserID: String? = nil
    ) {
        self.roomID = roomID
        self.userID = userID
        self.credentials = credentials
        self.signalingUserID = signalingUserID
    }

    /// Creates Agora room parameters.
    init(
        roomID: String,
        userID: String,
        token: String
    ) {
        self.init(roomID: roomID, userID: userID, credentials: .agora(token: token))
    }
}
