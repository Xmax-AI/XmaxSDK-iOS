//
//  RealtimeSession.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// An Xmax realtime generation session.
struct RealtimeSession: Equatable, Sendable {

    /// The server session identifier.
    let id: String

    /// The session's server user identifier.
    let userID: String?

    /// The server-reported session state.
    let status: String?

    /// The session's RTC connection information.
    let connection: RealtimeSessionConnection?

    /// The server-reported session closure reason.
    let closeReason: String?

    /// The assigned model instance used for HTTP event relay.
    let modelID: String?

    /// Creates a session with optional HTTP relay routing.
    init(
        id: String,
        userID: String?,
        status: String?,
        connection: RealtimeSessionConnection?,
        closeReason: String?,
        modelID: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.status = status
        self.connection = connection
        self.closeReason = closeReason
        self.modelID = modelID
    }
}
