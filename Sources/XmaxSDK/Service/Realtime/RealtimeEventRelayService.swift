//
//  RealtimeEventRelayService.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Submits complete generation controls through HTTP independently of RTC delivery.
final class RealtimeEventRelayService: Sendable {

    /// The authenticated realtime API service for the selected environment.
    private let apiService: any ApiServicing

    /// Creates an HTTP relay using the session's API service.
    init(apiService: any ApiServicing) {
        self.apiService = apiService
    }

    /// Submits one frozen command and accepts both new and previously accepted receipts.
    ///
    /// Cancellation stops the local request without withdrawing a command already accepted by
    /// the server. This method does not retry or confirm generation readiness.
    ///
    /// - Parameters:
    ///   - sessionID: The session receiving the command.
    ///   - modelID: The assigned model instance returned as `modelUid`.
    ///   - message: The complete JSON command, including its original `xid`.
    /// - Throws: An error if the request fails, its receipt is invalid, or the task is cancelled.
    func relay(
        sessionID: String,
        modelID: String,
        message: String
    ) async throws {
        try Task.checkCancellation()
        let data = Data(message.utf8)
        let command = try JSONDecoder().decode(Command.self, from: data)
        let body = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "modelId": modelID,
            "data": try JSONSerialization.jsonObject(with: data),
        ])
        let startedAt = ProcessInfo.processInfo.systemUptime
        let receipt = try await apiService.request(
            .post,
            path: "/client-event/relay",
            body: body,
            as: Receipt.self
        )
        try Task.checkCancellation()
        guard receipt.xid == command.xid, let accepted = receipt.accepted else {
            throw XmaxError(
                code: .apiError,
                message: "Server returned invalid event relay response"
            )
        }

        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        XmaxLogger.room.info(
            message: "HTTP 信令转发 (HTTP Signaling Relay)\n"
                + "├─ event: \(command.event), xid: \(command.xid)\n"
                + "├─ sessionId: \(sessionID), modelId: \(modelID)\n"
                + "└─ accepted: \(accepted), elapsed: \(elapsed) ms"
        )
    }

    /// Identifies the frozen command without changing its payload.
    private struct Command: Decodable {
        /// The generation control event.
        let event: String
        /// The logical identifier shared with RTC delivery.
        let xid: String
    }

    /// A relay receipt whose fields must be validated before accepting it.
    private struct Receipt: Decodable, Sendable {
        /// The command identifier echoed by the server.
        let xid: String?
        /// Whether this submission was newly accepted; `false` also represents a valid receipt.
        let accepted: Bool?

        /// The response field names.
        private enum CodingKeys: String, CodingKey {
            /// The echoed command identifier.
            case xid
            /// The submission acceptance field.
            case accepted
        }

        /// Decodes optional fields strictly by type so invalid receipts can be rejected together.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            xid = try? container.decode(String.self, forKey: .xid)
            accepted = try? container.decode(Bool.self, forKey: .accepted)
        }
    }
}
