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

    /// The room authentication token.
    let token: String
}
