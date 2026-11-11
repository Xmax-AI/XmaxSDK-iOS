//
//  XmaxRealtimeErrorManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Logs realtime errors and forwards runtime failures for coordinated lifecycle termination.
final class XmaxRealtimeErrorManager: @unchecked Sendable {

    /// A handler that terminates resources affected by a current runtime failure.
    typealias FailureHandler =
        @Sendable (
            XmaxError,
            XmaxRealtimeLifecycleManager.TerminationScope,
            @escaping @Sendable () -> Bool
        ) async -> Void

    /// The lock protecting failure revisions and the failure handler.
    private let lock = NSLock()

    /// The revision used to reject failures from previous media bindings.
    private var mediaRevision = UUID()

    /// The revision used to reject failures from previous connections.
    private var connectionRevision = UUID()

    /// The handler that forwards current failures to lifecycle termination.
    private var failureHandler: FailureHandler?

    /// Sets the runtime failure handler.
    ///
    /// - Parameter handler: The handler receiving an error, cleanup scope, and validity check.
    func setFailureHandler(
        _ handler: @escaping FailureHandler
    ) {
        lock.withLock {
            failureHandler = handler
        }
    }

    /// Invalidates pending failures from a completed lifecycle.
    ///
    /// - Parameter target: The released resource scope. Full cleanup invalidates both connection
    ///   and media failures.
    func invalidatePendingFailures(
        target: XmaxRealtimeLifecycleManager.TerminationScope = .all
    ) {
        guard !target.retainsConnection else {
            return
        }
        lock.withLock {
            connectionRevision = UUID()
            if target == .all {
                mediaRevision = UUID()
            }
        }
    }

    /// Forwards a runtime failure asynchronously, or logs it if no scope or handler is supplied.
    ///
    /// - Parameters:
    ///   - error: The runtime failure to handle.
    ///   - target: The affected resources, or `nil` to log without terminating the lifecycle.
    func forward(
        _ error: XmaxError,
        target: XmaxRealtimeLifecycleManager.TerminationScope? = nil
    ) {
        let (revision, handler) = lock.withLock {
            (target == .all ? mediaRevision : connectionRevision, failureHandler)
        }

        Task { [self] in
            guard let target, let handler else {
                await report(error)
                return
            }

            await handler(
                error,
                target,
                { [weak self] in
                    guard let self else {
                        return false
                    }
                    return lock.withLock {
                        (target == .all ? mediaRevision : connectionRevision) == revision
                    }
                }
            )
        }
    }

    /// Logs a realtime error code and message.
    ///
    /// - Parameter error: The SDK error to log.
    func report(
        _ error: XmaxError
    ) async {
        XmaxLogger.realtime.error(
            message: "实时服务错误 (Realtime Service Error)\n"
                + "├─ \(XmaxLogger.localized("错误码：", "Error Code: "))\(error.code.rawValue)\n"
                + "└─ \(XmaxLogger.localized("信息：", "Message: "))\(error.message)"
        )
    }
}
