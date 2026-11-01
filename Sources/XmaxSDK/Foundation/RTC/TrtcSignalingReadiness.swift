//
//  TrtcSignalingReadiness.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Delays room broadcasts until their intended remote recipient has entered the room.
final class TrtcSignalingReadiness: @unchecked Sendable {

    /// Protects membership, closure, and pending asynchronous waits.
    private let lock = NSLock()

    /// The expected signaling user; `nil` permits ordinary room broadcasts.
    private var expectedUserID: String?

    /// The remote users reported by native room events.
    private var presentUsers: Set<String> = []

    /// Whether this room has been invalidated.
    private var closed = false

    /// The pending waits, individually removed on cancellation.
    private var waiters: [UUID: AsyncThrowingStream<Void, any Error>.Continuation] = [:]

    /// Whether signaling currently has its intended receiver.
    var isReady: Bool {
        lock.withLock { !closed && recipientIsPresent }
    }

    /// Whether the configured recipient is in the room; accessed only while holding the lock.
    private var recipientIsPresent: Bool {
        expectedUserID.map { presentUsers.contains($0) } ?? true
    }

    /// Selects the recipient while retaining membership events received before configuration.
    func expectUser(
        _ userID: String?
    ) {
        let completed = lock.withLock {
            let normalized = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
            expectedUserID = normalized?.isEmpty == false ? normalized : nil
            return takeReadyWaiters()
        }
        completed.forEach { $0.finish() }
    }

    /// Updates native room membership independently of video publication.
    func setUserPresent(
        _ userID: String,
        present: Bool
    ) {
        let completed = lock.withLock {
            guard !closed else { return [AsyncThrowingStream<Void, any Error>.Continuation]() }
            if present { presentUsers.insert(userID) } else { presentUsers.remove(userID) }
            return takeReadyWaiters()
        }
        completed.forEach { $0.finish() }
    }

    /// Waits for membership, respecting caller cancellation and room closure.
    ///
    /// The generation operation owns the startup deadline; this wait does not extend it.
    func waitUntilReady() async throws {
        try Task.checkCancellation()
        let id = UUID()
        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            }
            let result = lock.withLock { () -> Bool? in
                if closed { return false }
                if recipientIsPresent { return true }
                waiters[id] = continuation
                return nil
            }
            if let result {
                if result {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: CancellationError())
                }
            }
        }
        for try await _ in stream {}
        try Task.checkCancellation()
    }

    /// Invalidates membership and releases all waits during room teardown.
    func close() {
        let pending = lock.withLock {
            closed = true
            presentUsers.removeAll()
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.finish(throwing: CancellationError()) }
    }

    /// Removes satisfied waits while holding the membership lock.
    private func takeReadyWaiters() -> [AsyncThrowingStream<Void, any Error>.Continuation] {
        guard !closed, recipientIsPresent else { return [] }
        let completed = Array(waiters.values)
        waiters.removeAll()
        return completed
    }
}
