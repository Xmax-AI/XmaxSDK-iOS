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

    /// The RTC room token.
    let token: String

    /// The remote user providing generated media.
    let botName: String?
}

/// A handler for realtime session heartbeat failure.
typealias RealtimeSessionHeartbeatFailureHandler =
    @Sendable (
        _ sessionID: String,
        _ error: XmaxError
    ) async -> Void
