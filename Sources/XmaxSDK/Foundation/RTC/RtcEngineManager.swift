//
//  RtcEngineManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Exclusive ownership of the process-wide RTC engine.
final class RtcEngineLease: @unchecked Sendable {

    /// The leased platform engine.
    let engine: any RtcPlatform

    /// Releases the native engine belonging to this lease.
    let destroy: @Sendable () -> Void

    /// The unique lease identifier.
    let id = UUID()

    /// Creates an exclusive engine lease.
    fileprivate init(
        engine: any RtcPlatform,
        destroy: @escaping @Sendable () -> Void
    ) {
        self.engine = engine
        self.destroy = destroy
    }
}

/// Serializes exclusive access to the process-wide RTC engine.
actor RtcEngineManager {

    /// A factory returning a platform engine for an application ID, or `nil` on failure.
    typealias EngineFactory = @Sendable (String) -> (any RtcPlatform)?

    /// The closure destroying the process-wide platform engine.
    typealias EngineDestructor = @Sendable () -> Void

    /// The shared engine lease manager.
    static let shared = RtcEngineManager()

    /// The default RTC application identifier.
    static let defaultAppID = "5588dfe2e7874bd08ea28f4968ec2d40"

    /// The RTC application identifier.
    private let appID: String

    /// The factory invoked after exclusive access is obtained.
    private let makeEngine: EngineFactory?

    /// The destructor invoked when a lease is released.
    private let destroyEngine: EngineDestructor?

    /// The active exclusive lease.
    private var activeLease: RtcEngineLease?

    /// The pending lease requests in acquisition order.
    private var requests: [Request] = []

    /// Creates an engine lease manager.
    init(
        appID: String = RtcEngineManager.defaultAppID,
        makeEngine: EngineFactory? = nil,
        destroyEngine: EngineDestructor? = nil
    ) {
        self.appID = appID
        self.makeEngine = makeEngine
        self.destroyEngine = destroyEngine
    }

    /// Waits for an exclusive RTC engine lease.
    ///
    /// - Returns: The exclusive lease held by this call.
    ///
    /// - Throws: An error if cancelled, the application ID is invalid, or engine creation fails.
    func acquire(
        provider: RtcProvider = .agora
    ) async throws -> RtcEngineLease {
        try Task.checkCancellation()

        if activeLease == nil, requests.isEmpty {
            let lease = try createLease(provider: provider)
            if Task.isCancelled {
                releaseActiveLease(lease)
                throw CancellationError()
            }

            activeLease = lease
            return lease
        }

        let requestID = UUID()
        let lease: RtcEngineLease = try await withTaskCancellationHandler(
            operation: {
                try await self.enqueueRequest(id: requestID, provider: provider)
            },
            onCancel: {
                Task {
                    await self.cancelRequest(id: requestID)
                }
            }
        )

        if Task.isCancelled {
            releaseActiveLease(lease)
            throw CancellationError()
        }

        return lease
    }

    /// Releases an active lease and serves the next waiter.
    ///
    /// - Parameter lease: The lease to return. Stale leases do not affect the active engine.
    func release(
        _ lease: RtcEngineLease
    ) {
        guard activeLease?.id == lease.id else {
            return
        }

        releaseActiveLease(lease)
    }

    /// Creates an engine with an exclusive lease.
    ///
    /// - Returns: The new engine lease.
    ///
    /// - Throws: An error if the application ID is empty or engine creation fails.
    private func createLease(
        provider: RtcProvider
    ) throws -> RtcEngineLease {
        let normalizedAppID = appID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard provider == .trtc || !normalizedAppID.isEmpty else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC App ID cannot be empty"
            )
        }
        let factory = makeEngine ?? (provider == .agora ? AgoraRtcPlatform.create : TrtcRtcPlatform.create)
        let destructor = destroyEngine ?? (provider == .agora ? AgoraRtcPlatform.destroyEngine : TrtcRtcPlatform.destroyEngine)
        guard let engine = factory(normalizedAppID) else {
            throw XmaxError(
                code: .rtcError,
                message: "Failed to create RTC Engine"
            )
        }

        return RtcEngineLease(engine: engine, destroy: destructor)
    }

    /// Destroys the engine for an active lease and serves pending requests.
    ///
    /// - Parameter lease: The lease to release.
    private func releaseActiveLease(
        _ lease: RtcEngineLease
    ) {
        guard activeLease == nil || activeLease?.id == lease.id else {
            return
        }

        activeLease = nil
        lease.destroy()
        fulfillNextRequest()
    }

    /// Delivers leases to waiters in request order.
    private func fulfillNextRequest() {
        while activeLease == nil, !requests.isEmpty {
            let request = requests.removeFirst()

            do {
                let lease = try createLease(provider: request.provider)
                activeLease = lease
                request.continuation.resume(returning: lease)
            } catch {
                request.continuation.resume(throwing: error)
            }
        }
    }

    /// Enqueues a lease request.
    ///
    /// - Parameter id: The identifier used to locate or cancel the request.
    ///
    /// - Returns: The exclusive lease delivered when available.
    ///
    /// - Throws: An error if the request is cancelled or engine creation fails.
    private func enqueueRequest(
        id: UUID,
        provider: RtcProvider
    ) async throws -> RtcEngineLease {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RtcEngineLease, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }

            requests.append(
                Request(
                    id: id,
                    provider: provider,
                    continuation: continuation
                )
            )
        }
    }

    /// Cancels a queued lease request.
    ///
    /// - Parameter id: The request identifier to cancel.
    private func cancelRequest(
        id: UUID
    ) {
        guard
            let index = requests.firstIndex(where: {
                $0.id == id
            })
        else {
            return
        }

        let request = requests.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
    }

}

private extension RtcEngineManager {

    /// A pending request for exclusive RTC engine ownership.
    struct Request {

        /// The lease request identifier.
        let id: UUID

        /// The provider requested by this waiter.
        let provider: RtcProvider

        /// The continuation awaiting engine ownership.
        let continuation: CheckedContinuation<RtcEngineLease, any Error>
    }
}
