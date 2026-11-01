//
//  RealtimeSessionServicingStub.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@testable import XmaxSDK

enum RealtimeSessionServicingCall: Equatable {
    case createSession(RealtimeModel)
    case startHeartbeat(String)
    case stopHeartbeat
    case closeSession(String)
}

final class RealtimeSessionServicingStub: RealtimeSessionServicing,
    @unchecked Sendable {

    // 测试配置
    private let session: RealtimeSession
    private let createError: (any Error)?
    private let closeError: (any Error)?

    // 并发状态
    private let lock = NSLock()
    private(set) var firstHeartbeatGraceSeconds: Int?
    private var storedCalls: [RealtimeSessionServicingCall] = []
    private var heartbeatFailureHandler:
        RealtimeSessionHeartbeatFailureHandler?

    init(
        session: RealtimeSession,
        createError: (any Error)? = nil,
        closeError: (any Error)? = nil
    ) {
        self.session = session
        self.createError = createError
        self.closeError = closeError
    }

    var calls: [RealtimeSessionServicingCall] {
        lock.withLock { storedCalls }
    }

    func createSession(model: RealtimeModel) async throws -> RealtimeSession {
        try lock.withLock {
            storedCalls.append(.createSession(model))
            if let createError {
                throw createError
            }
            return session
        }
    }

    func startHeartbeat(
        sessionID: String,
        firstHeartbeatGraceSeconds: Int?,
        onFailure: @escaping RealtimeSessionHeartbeatFailureHandler
    ) {
        lock.withLock {
            self.firstHeartbeatGraceSeconds = firstHeartbeatGraceSeconds
            storedCalls.append(.startHeartbeat(sessionID))
            heartbeatFailureHandler = onFailure
        }
    }

    func stopHeartbeat() {
        lock.withLock {
            storedCalls.append(.stopHeartbeat)
            heartbeatFailureHandler = nil
        }
    }

    func closeSession(sessionID: String) async throws {
        try lock.withLock {
            storedCalls.append(.closeSession(sessionID))
            if let closeError {
                throw closeError
            }
        }
    }

    func failHeartbeat(
        sessionID: String,
        error: XmaxError
    ) async {
        let handler = lock.withLock { heartbeatFailureHandler }
        await handler?(sessionID, error)
    }
}
