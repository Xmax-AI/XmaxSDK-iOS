//
//  RealtimeSessionServicing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// An interface for session requests and heartbeat lifecycle.
protocol RealtimeSessionServicing: Sendable {

    /// Creates a realtime session for the requested model.
    ///
    /// - Parameter model: The realtime generation model.
    ///
    /// - Returns: The server session and its RTC credentials.
    ///
    /// - Throws: An error if the request fails, required fields are missing, or the task is
    ///   cancelled.
    func createSession(
        model: RealtimeModel
    ) async throws -> RealtimeSession

    /// Starts a session heartbeat, replacing the previous task.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier to keep alive.
    ///   - firstHeartbeatGraceSeconds: The startup allowance sent only in the first request.
    ///   - onFailure: The handler receiving the session identifier and heartbeat error.
    func startHeartbeat(
        sessionID: String,
        firstHeartbeatGraceSeconds: Int?,
        onFailure: @escaping RealtimeSessionHeartbeatFailureHandler
    )

    /// Stops the heartbeat and invalidates pending failure notifications.
    func stopHeartbeat()

    /// Closes a server session.
    ///
    /// - Parameter sessionID: The session identifier to close.
    ///
    /// - Throws: An error if closure fails or the task is cancelled.
    func closeSession(
        sessionID: String
    ) async throws
}

extension RealtimeSessionServicing {
    /// Starts a heartbeat without a startup allowance for internal callers that do not measure it.
    func startHeartbeat(
        sessionID: String,
        onFailure: @escaping RealtimeSessionHeartbeatFailureHandler
    ) {
        startHeartbeat(sessionID: sessionID, firstHeartbeatGraceSeconds: nil, onFailure: onFailure)
    }
}
