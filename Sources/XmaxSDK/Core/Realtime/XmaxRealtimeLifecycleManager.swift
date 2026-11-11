//
//  XmaxRealtimeLifecycleManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Owns operation admission, lifecycle state, and scoped termination for a realtime manager.
///
/// Media, connection, and generation components execute work inside admitted operations. This
/// coordinator validates operation tokens, prioritizes foreground work over quality adaptation,
/// and invokes injected cleanup without owning RTC, capture, or rendering resources.
actor XmaxRealtimeLifecycleManager {

    /// The kinds of mutually coordinated media and realtime operations.
    enum OperationKind: Sendable {

        /// Creates, stops, or reconfigures local media.
        case media

        /// Establishes a realtime connection.
        case connection

        /// Starts generation.
        case generation

        /// Switches cameras and resumes generation when needed.
        case cameraSwitch

        /// Updates conditions or output dimensions without changing the generation lifecycle.
        case configuration
    }

    /// The resources affected by a termination request.
    enum TerminationScope: Int, Sendable {

        /// Releases the generation task while retaining the connection and local media.
        case generation = -2

        /// Releases the task and RTC publication while retaining the connection and local media.
        case publication = -1

        /// Releases connection and generation resources while retaining local media.
        case connection

        /// Releases connection, generation, and local media resources.
        case all

        var retainsConnection: Bool { self == .generation || self == .publication }

        /// Determines whether this cleanup scope affects an operation.
        ///
        /// - Parameter kind: The operation kind to check.
        ///
        /// - Returns: `true` if this scope includes the operation.
        func affects(
            _ kind: OperationKind
        ) -> Bool {
            switch self {
            case .generation, .publication:
                kind == .generation || kind == .configuration || kind == .cameraSwitch
            case .connection:
                kind != .media
            case .all:
                true
            }
        }
    }

    /// The session identifier and local media availability after cleanup.
    struct CleanupResult: Sendable {

        /// The session identifier involved in cleanup, if any.
        let sessionID: String?

        /// Whether usable local media remains after cleanup.
        let hasLocalMedia: Bool

        /// An error encountered while stopping generation without leaving the room.
        let error: XmaxError?

        /// The last generation task stopped in the retained room.
        let stoppedTaskID: String?

        /// Creates a cleanup result.
        init(
            sessionID: String? = nil,
            hasLocalMedia: Bool = false,
            error: XmaxError? = nil,
            stoppedTaskID: String? = nil
        ) {
            self.sessionID = sessionID
            self.hasLocalMedia = hasLocalMedia
            self.error = error
            self.stoppedTaskID = stoppedTaskID
        }
    }

    /// A token that guards operation validity and defines failure cleanup.
    struct Token: Sendable {

        /// The lease that tracks the operation's validity.
        fileprivate let lease: OperationLease

        /// Sets the resources to release if the operation fails or is cancelled.
        ///
        /// - Parameter scope: The resources to release.
        func setFailureScope(
            _ scope: TerminationScope
        ) {
            lease.setFailureScope(scope)
        }

        /// Verifies that the operation remains current and has not been cancelled.
        ///
        /// - Throws: An error if the operation is no longer current or has been cancelled.
        func ensureCurrent() throws {
            try lease.ensureCurrent()
        }

        /// Whether the operation is still current.
        var isCurrent: Bool {
            lease.isCurrent
        }
    }

    /// A handler that releases scoped resources and reports the cleanup result.
    ///
    /// - Parameters:
    ///   - scope: The resource scope to release.
    ///   - taskID: The generation task to end, or an empty string if no task exists.
    ///
    /// - Returns: The session identifier and local media availability after cleanup.
    typealias CleanupHandler =
        @Sendable (
            _ scope: TerminationScope,
            _ taskID: String
        ) async -> CleanupResult

    // MARK: - Dependencies

    /// The manager that logs errors and forwards runtime failures.
    private let errorManager: XmaxRealtimeErrorManager

    /// The internal hook invoked after committing state and before notifying the app.
    private let onStateChanged: (@Sendable (RealtimeState) async -> Void)?

    /// The handler that releases resources for a termination scope.
    private let cleanup: CleanupHandler

    // MARK: - State

    /// The realtime state snapshot exposed to your app.
    private var state = RealtimeState(connectionState: .idle)

    /// The listener for connection and generation state changes.
    private var stateListener: RealtimeStateListener?

    /// The operation currently admitted by the coordinator.
    private var activeOperation: Operation?

    /// The latest generation request, including one waiting for its predecessor's cleanup.
    private var generationRequest: GenerationRequest?

    /// The merged termination request currently being processed.
    private var termination: Termination?

    /// The number of pending or executing foreground requests, which take priority over adaptation.
    private var foregroundRequests = 0

    /// Creates a realtime lifecycle coordinator.
    init(
        errorManager: XmaxRealtimeErrorManager,
        onStateChanged: (@Sendable (RealtimeState) async -> Void)? = nil,
        cleanup: @escaping CleanupHandler
    ) {
        self.errorManager = errorManager
        self.onStateChanged = onStateChanged
        self.cleanup = cleanup
    }

    /// The realtime state currently exposed to your app.
    var currentState: RealtimeState {
        state
    }

    /// Replaces the state listener and immediately delivers the current state.
    ///
    /// - Parameter listener: The state change handler, or `nil` to remove it.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async {
        stateListener = listener

        if let listener {
            await listener(state)
        }
    }

    /// Admits an operation, replacing pending generation requests and rejecting other conflicts.
    ///
    /// - Parameters:
    ///   - kind: The requested operation kind.
    ///   - failureScope: The failure or cancellation cleanup scope, or `nil` to omit automatic
    ///     cleanup.
    ///   - body: The operation body, which must check its token across asynchronous boundaries.
    ///
    /// - Returns: The result of the completed operation.
    ///
    /// - Throws: An error if an incompatible operation is active, execution fails, or the
    ///   operation is cancelled or replaced.
    func run<Value: Sendable>(
        kind: OperationKind,
        failureScope: TerminationScope? = nil,
        operation body: @escaping @Sendable (Token) async throws -> Value
    ) async throws -> Value {
        foregroundRequests += 1
        defer {
            foregroundRequests -= 1
        }

        if kind == .generation {
            return try await runGeneration(
                failureScope: failureScope,
                operation: body
            )
        }

        return try await runOperation(
            kind: kind,
            failureScope: failureScope,
            operation: body
        )
    }

    /// Executes an operation after background configuration finishes.
    ///
    /// - Parameters:
    ///   - kind: The operation's admission kind.
    ///   - failureScope: The resources released on failure or cancellation.
    ///   - request: The generation request owning this operation, if any.
    ///   - body: The work guarded by the admitted operation's token.
    ///
    /// - Returns: The operation's successful result.
    ///
    /// - Throws: An error if admission is rejected, execution fails, or the operation is cancelled.
    private func runOperation<Value: Sendable>(
        kind: OperationKind,
        failureScope: TerminationScope?,
        request: GenerationRequest? = nil,
        operation body: @escaping @Sendable (Token) async throws -> Value
    ) async throws -> Value {
        if let background = activeOperation, background.background {
            // Finish committing the background configuration before applying a foreground request.
            await background.waitForCompletion()
            finish(background)
        }

        try Task.checkCancellation()
        if let request, generationRequest !== request {
            throw Self.cancelledError()
        }
        guard termination == nil, activeOperation == nil,
            request != nil || generationRequest == nil
        else {
            let error = XmaxError(
                code: .invalidConfiguration,
                message: "Another realtime operation is in progress; wait for it to finish"
            )
            await errorManager.report(error)
            throw error
        }

        // An active generation request updates conditions using the shared configuration operation.
        let operationKind: OperationKind =
            kind == .generation && state.connectionState == .generating
            ? .configuration : kind
        let operation = Operation(
            kind: operationKind,
            failureScope: failureScope,
            generationRequest: request
        )
        let token = Token(lease: operation.lease)
        let task = Task {
            try await body(token)
        }

        operation.cancel = {
            task.cancel()
        }
        operation.waitForCompletion = {
            _ = try? await task.value
        }

        activeOperation = operation

        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                operation.lease.invalidate()
                task.cancel()
            }

            try Task.checkCancellation()
            try token.ensureCurrent()

            let completionState = operation.completionState
            finish(operation)
            if let completionState {
                await setState(completionState)
            }
            return value
        } catch {
            return try await handleFailure(
                error,
                operation: operation
            )
        }
    }

    /// Runs a low-priority quality update when idle, skipping it while busy.
    ///
    /// - Parameter body: The transport update, which must check its token after asynchronous
    ///   boundaries.
    ///
    /// - Returns: Whether the update was admitted and completed successfully.
    ///
    /// - Throws: An error if an admitted update fails or is terminated.
    func runAdaptiveConfiguration(
        _ body: @escaping @Sendable (Token) async throws -> Void
    ) async throws -> Bool {
        guard termination == nil, activeOperation == nil,
            generationRequest == nil, foregroundRequests == 0,
            state.connectionState == .generating
        else {
            return false
        }

        let operation = Operation(
            kind: .configuration,
            failureScope: nil,
            background: true
        )
        let token = Token(lease: operation.lease)
        let task = Task {
            try await body(token)
        }

        operation.cancel = {
            task.cancel()
        }
        operation.waitForCompletion = {
            _ = try? await task.value
        }

        activeOperation = operation
        defer {
            finish(operation)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            operation.lease.invalidate()
            task.cancel()
        }

        try token.ensureCurrent()
        return true
    }

    /// Commits state produced by a current operation.
    ///
    /// - Parameters:
    ///   - nextState: The state to publish.
    ///   - token: The validity token for this operation.
    ///
    /// - Throws: An error if the operation is no longer current or has been cancelled.
    func commit(
        _ nextState: RealtimeState,
        token: Token
    ) async throws {
        try token.ensureCurrent()

        if nextState.connectionState == .preparing,
            let activeOperation, activeOperation.lease === token.lease,
            activeOperation.kind == .media
        {
            activeOperation.didBeginMediaPreparation = true
        }

        await setState(nextState)
    }

    /// Stages the final state of an operation for publication after it releases admission.
    ///
    /// Callers finish their resource work before staging completion. Unlike an intermediate
    /// commit, the listener can immediately submit the next operation when it receives this state.
    ///
    /// - Parameters:
    ///   - nextState: The state to publish after the operation releases admission.
    ///   - token: The token identifying the operation being completed.
    ///
    /// - Throws: An error if the token is cancelled or no longer identifies the active operation.
    func complete(
        _ nextState: RealtimeState,
        token: Token
    ) throws {
        try token.ensureCurrent()
        guard let activeOperation, activeOperation.lease === token.lease else {
            throw Self.cancelledError()
        }

        activeOperation.completionState = nextState
    }

    /// Marks preparing media as ready when its current preview becomes available.
    ///
    /// - Parameter isCurrent: A closure verifying that the notification belongs to the current
    ///   media.
    func localPreviewDidBecomeReady(
        isCurrent: @Sendable () -> Bool
    ) async {
        guard state.connectionState == .preparing, isCurrent() else {
            return
        }

        await setState(RealtimeState(connectionState: .ready))
    }

    /// Disconnects realtime and waits for connection operations and resources to finish cleanup.
    ///
    /// - Parameter reason: The disconnection reason delivered with the final state.
    func disconnect(
        reason: RealtimeReason = .normal
    ) async {
        let task = await beginDisconnect(reason: reason)
        await task?.value
    }

    /// Cancels the active generation operation and waits for its publication cleanup.
    func stopGeneration() async throws -> String? {
        if let termination, !termination.target.retainsConnection {
            await termination.task.value
            return nil
        }

        switch state.connectionState {
        case .connecting where activeOperation?.generationRequest != nil:
            await disconnect()
        case .connected, .generating:
            let pending = await requestTermination(.publication)
            await pending.task.value
            if let error = pending.cleanupError {
                throw error
            }
            return pending.stoppedTaskID
        default:
            if let request = generationRequest {
                request.cancel()
                await request.waitForCompletion()
            }
        }
        return nil
    }

    /// Begins connection cleanup while preserving local media.
    ///
    /// - Parameter reason: The disconnection reason delivered with the final state.
    ///
    /// - Returns: The cleanup task, or `nil` if no connection or related operation requires
    ///   termination.
    func beginDisconnect(
        reason: RealtimeReason
    ) async -> Task<Void, Never>? {
        let hasConnectionOperation =
            activeOperation.map {
                TerminationScope.connection.affects($0.kind)
            } ?? false

        guard
            hasConnectionOperation || generationRequest != nil || termination != nil
                || (state.connectionState != .idle && state.connectionState != .preparing
                    && state.connectionState != .ready)
        else {
            return nil
        }

        let pending = await requestTermination(
            .connection,
            reason: reason
        )
        return pending.task
    }

    /// Terminates scoped operations, merging concurrent requests into the broadest cleanup scope.
    ///
    /// - Parameters:
    ///   - target: The resources to terminate.
    ///   - reason: The termination reason delivered with the final state.
    func terminate(
        _ target: TerminationScope,
        reason: RealtimeReason = .normal
    ) async {
        let pending = await requestTermination(
            target,
            reason: reason
        )
        await pending.task.value
    }

    /// Terminates resources affected by a current failure and reports it in the final state.
    ///
    /// - Parameters:
    ///   - error: The runtime failure that triggered termination.
    ///   - target: The resources to terminate.
    ///   - isCurrent: A closure verifying that the failure belongs to the current lifecycle.
    func terminate(
        with error: XmaxError,
        target: TerminationScope,
        isCurrent: @Sendable () -> Bool = {
            true
        }
    ) async {
        guard isCurrent() else {
            return
        }

        // Ignore late remote failures during cleanup; media failures may still expand the cleanup scope.
        if let termination, !termination.target.retainsConnection, target != .all {
            return
        }

        let pending = await requestTermination(
            target,
            error: error,
            reason: .failure(error)
        )
        await pending.task.value
    }
}

private extension XmaxRealtimeLifecycleManager {

    /// A generation request's cancellation handle and resource-completion barrier.
    final class GenerationRequest: @unchecked Sendable {

        /// Cancels the request's worker; installed before publishing the request.
        var cancel: @Sendable () -> Void = {}

        /// Protects completion and its suspended successors.
        private let lock = NSLock()

        /// Whether all work and required cleanup have completed.
        private var completed = false

        /// The successors waiting for resource ownership to become available.
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Waits for completion even when the waiting request has been cancelled.
        func waitForCompletion() async {
            await withCheckedContinuation { continuation in
                let alreadyCompleted = lock.withLock {
                    if completed {
                        return true
                    }
                    waiters.append(continuation)
                    return false
                }

                if alreadyCompleted {
                    continuation.resume()
                }
            }
        }

        /// Releases successors after work and cleanup, before state callbacks are delivered.
        func finish() {
            let pending = lock.withLock {
                completed = true
                let pending = waiters
                waiters.removeAll()
                return pending
            }

            for waiter in pending {
                waiter.resume()
            }
        }
    }

    /// Replaces the previous generation request and waits for its resource cleanup.
    ///
    /// - Parameters:
    ///   - failureScope: The resources released if generation fails or is cancelled.
    ///   - body: The generation work guarded by its operation token.
    ///
    /// - Returns: The latest request's successful result.
    ///
    /// - Throws: An error if another operation conflicts, generation fails, or the request is cancelled.
    func runGeneration<Value: Sendable>(
        failureScope: TerminationScope?,
        operation body: @escaping @Sendable (Token) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard (termination == nil || generationRequest != nil),
            activeOperation == nil || activeOperation?.background == true
                || activeOperation?.generationRequest != nil
        else {
            let error = XmaxError(
                code: .invalidConfiguration,
                message: "Another realtime operation is in progress; wait for it to finish"
            )
            await errorManager.report(error)
            throw error
        }

        let previous = generationRequest
        let request = GenerationRequest()
        let task = Task {
            await previous?.waitForCompletion()
            defer { request.finish() }

            try Task.checkCancellation()
            return try await runOperation(
                kind: .generation,
                failureScope: failureScope,
                request: request,
                operation: body
            )
        }

        request.cancel = { task.cancel() }
        generationRequest = request
        previous?.cancel()
        defer {
            if generationRequest === request {
                generationRequest = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            request.cancel()
        }
    }

    /// A thread-safe lease for operation validity and failure cleanup.
    final class OperationLease: @unchecked Sendable {

        /// The lock protecting lease validity and the terminal error.
        private let lock = NSLock()

        /// Whether the operation can still commit results.
        private var valid = true

        /// The terminal error returned after the operation is invalidated.
        private var terminalError: XmaxError?

        /// The resources to release if this operation fails.
        private var storedFailureScope: TerminationScope?

        /// Creates an operation lease with the specified failure scope.
        ///
        /// - Parameter failureScope: The cleanup scope on failure or cancellation, or `nil` to omit
        ///   automatic cleanup.
        init(
            failureScope: TerminationScope?
        ) {
            storedFailureScope = failureScope
        }

        /// Whether the lease remains valid.
        var isCurrent: Bool {
            lock.withLock {
                valid
            }
        }

        /// The first terminal error, which may be `nil` for explicit cancellation.
        var failure: XmaxError? {
            lock.withLock {
                terminalError
            }
        }

        /// The cleanup scope on failure or cancellation.
        var failureScope: TerminationScope? {
            lock.withLock {
                storedFailureScope
            }
        }

        /// Updates the cleanup scope on failure or cancellation.
        ///
        /// - Parameter scope: The resources to release.
        func setFailureScope(
            _ scope: TerminationScope
        ) {
            lock.withLock {
                storedFailureScope = scope
            }
        }

        /// Invalidates the lease while retaining the first terminal error.
        ///
        /// - Parameter error: The terminal error, or `nil` for explicit cancellation.
        func invalidate(
            error: XmaxError? = nil
        ) {
            lock.withLock {
                valid = false
                if terminalError == nil {
                    terminalError = error
                }
            }
        }

        /// Verifies that the lease is valid and the current task has not been cancelled.
        ///
        /// - Throws: The terminal or cancellation error if the lease is invalid, or a task
        ///   cancellation error.
        func ensureCurrent() throws {
            let result = lock.withLock {
                (valid, terminalError)
            }

            guard result.0 else {
                if let error = result.1 {
                    throw error
                }
                throw Self.cancelledError()
            }

            try Task.checkCancellation()
        }

        /// Creates a realtime operation cancellation error.
        private static func cancelledError() -> XmaxError {
            XmaxError(
                code: .cancelled,
                message: "Realtime operation was cancelled"
            )
        }
    }

    /// A realtime operation and its cancellation and cleanup controls.
    final class Operation: @unchecked Sendable {

        /// Whether this operation owns the preparation state it may roll back on failure.
        var didBeginMediaPreparation = false

        /// The final state published only after successful completion and admission release.
        var completionState: RealtimeState?

        /// The identifier distinguishing this operation from concurrent requests.
        let id = UUID()

        /// The operation kind used for admission and termination decisions.
        let kind: OperationKind

        /// Whether this is a background operation that yields to foreground requests.
        let background: Bool

        /// The generation request owning this operation, retained through rollback.
        let generationRequest: GenerationRequest?

        /// The lease managing validity and failure cleanup for this operation.
        let lease: OperationLease

        /// The closure that cancels the underlying task.
        var cancel: @Sendable () -> Void = {
        }

        /// The closure that awaits underlying task completion before releasing its resources.
        var waitForCompletion: @Sendable () async -> Void = {
        }

        /// The resource cleanup task assigned to this operation.
        var terminationTask: Task<Void, Never>?

        /// Creates an operation record.
        ///
        /// - Parameters:
        ///   - kind: The operation kind governing cancellation and cleanup.
        ///   - failureScope: The cleanup scope on failure or cancellation.
        ///   - background: Whether this is a low-priority background configuration operation.
        ///   - generationRequest: The generation request owning this operation, if any.
        init(
            kind: OperationKind,
            failureScope: TerminationScope?,
            background: Bool = false,
            generationRequest: GenerationRequest? = nil
        ) {
            self.kind = kind
            self.background = background
            self.generationRequest = generationRequest
            lease = OperationLease(failureScope: failureScope)
        }
    }

    /// A termination request shared by concurrent cleanup callers.
    final class Termination: @unchecked Sendable {

        /// The identifier distinguishing successive termination lifecycles.
        let id = UUID()

        /// The resources to release for this termination.
        var target: TerminationScope

        /// The reason delivered to the state listener after cleanup.
        var reason: RealtimeReason

        /// The failure that triggered termination, or `nil` for an explicit request.
        var error: XmaxError?

        /// The outcome of cleanup that keeps the RTC room open.
        var cleanupError: XmaxError?

        /// The last task stopped by cleanup that kept the RTC room open.
        var stoppedTaskID: String?

        /// The server session identifier involved in cleanup.
        var sessionID: String?

        /// The operations that must complete before resources are released.
        var waitForOperations: [@Sendable () async -> Void] = []

        /// The shared cleanup task awaited by concurrent termination requests.
        var task: Task<Void, Never>!

        /// Creates a termination record.
        init(
            target: TerminationScope,
            reason: RealtimeReason,
            error: XmaxError?
        ) {
            self.target = target
            self.reason = reason
            self.error = error
        }
    }

    /// Completes failed operation cleanup and throws the corresponding error.
    ///
    /// - Parameters:
    ///   - error: The error raised during operation execution.
    ///   - operation: The operation that failed.
    ///
    /// - Throws: The terminal or cancellation error for cancellation, or the converted SDK error
    ///   for other failures.
    func handleFailure<Value: Sendable>(
        _ error: any Error,
        operation: Operation
    ) async throws -> Value {
        let operationWasCancelled =
            XmaxError.isCancellation(error) || !operation.lease.isCurrent || Task.isCancelled

        if operationWasCancelled {
            // Cancelling a configuration request does not stop generation; explicit termination still awaits cleanup.
            if (operation.kind == .configuration || operation.lease.failureScope == nil),
                operation.terminationTask == nil,
                termination == nil
            {
                finish(operation)
                if operation.didBeginMediaPreparation, state.connectionState == .preparing {
                    await setState(RealtimeState(connectionState: .idle))
                }
                throw Self.cancelledError()
            }

            let terminationTask: Task<Void, Never>
            if let assignedTask = operation.terminationTask {
                terminationTask = assignedTask
            } else if let termination {
                terminationTask = termination.task
            } else {
                let isReplacement = operation.generationRequest != nil && generationRequest != nil
                    && operation.generationRequest !== generationRequest
                let scope = isReplacement && state.connectionState == .connected
                    ? .generation : operation.lease.failureScope ?? TerminationScope.connection
                let pending = await requestTermination(
                    scope,
                    origin: operation
                )
                terminationTask = pending.task
            }

            await terminationTask.value
            finish(operation)

            if let failure = operation.lease.failure {
                throw failure
            }
            throw Self.cancelledError()
        }

        let resolvedError = XmaxError.from(error)
        if operation.kind != .configuration, let scope = operation.lease.failureScope {
            let pending = await requestTermination(
                scope,
                error: resolvedError,
                reason: .failure(resolvedError),
                origin: operation
            )
            await pending.task.value
        } else {
            finish(operation)
            if operation.didBeginMediaPreparation, state.connectionState == .preparing {
                await setState(RealtimeState(connectionState: .idle))
            }
            await errorManager.report(resolvedError)
            throw resolvedError
        }

        finish(operation)
        throw resolvedError
    }

    /// Creates or merges a termination request and cancels operations within its scope.
    ///
    /// - Parameters:
    ///   - target: The cleanup scope requested by this call.
    ///   - error: The triggering failure, or `nil` for an explicit termination request.
    ///   - reason: The reason carried by the final state.
    ///   - origin: The failed operation requesting cleanup, or `nil` for an external termination
    ///     request.
    ///
    /// - Returns: The merged request and its shared cleanup task.
    func requestTermination(
        _ target: TerminationScope,
        error: XmaxError? = nil,
        reason: RealtimeReason = .normal,
        origin: Operation? = nil
    ) async -> Termination {
        if origin == nil {
            generationRequest?.cancel()
            generationRequest = nil
        }

        let pending: Termination
        if let termination {
            pending = termination
            if target.rawValue > pending.target.rawValue {
                pending.target = target
            }
            if pending.error == nil {
                pending.error = error
            }
            if let error, pending.error == error {
                pending.reason = .failure(error)
            }
        } else {
            pending = Termination(
                target: target,
                reason: reason,
                error: error
            )
            termination = pending
            pending.task = Task { [weak self] in
                await self?.performTermination(id: pending.id)
            }
        }

        if let activeOperation,
            activeOperation !== origin,
            pending.target.affects(activeOperation.kind)
        {
            activeOperation.lease.invalidate(error: pending.error)
            activeOperation.terminationTask = pending.task
            activeOperation.cancel()
            pending.waitForOperations.append(
                activeOperation.waitForCompletion
            )
        } else if let origin {
            origin.lease.invalidate(error: error)
            origin.terminationTask = pending.task
            pending.waitForOperations.append(origin.waitForCompletion)
        }

        if !pending.target.retainsConnection {
            await setState(
                RealtimeState(
                    connectionState: .disconnecting,
                    sessionID: state.sessionID,
                    reason: nil
                )
            )
        }

        return pending
    }

    /// Waits for affected operations, releases resources, and publishes the final state.
    ///
    /// - Parameter id: The termination record to execute. Stale requests do not perform cleanup.
    func performTermination(
        id: UUID
    ) async {
        guard let pending = termination, pending.id == id else {
            return
        }

        while true {
            let waiters = pending.waitForOperations
            pending.waitForOperations.removeAll()
            for waiter in waiters {
                await waiter()
            }

            let requestedTarget = pending.target
            let taskID = state.taskID ?? ""
            let result = await cleanup(
                requestedTarget,
                taskID
            )
            pending.cleanupError = pending.cleanupError ?? result.error
            if let sessionID = result.sessionID {
                pending.sessionID = sessionID
            }

            guard pending.target == requestedTarget, pending.waitForOperations.isEmpty else {
                continue
            }
            pending.stoppedTaskID = result.stoppedTaskID

            let connectionState: RealtimeConnectionState
            if requestedTarget.retainsConnection {
                connectionState = .connected
            } else if requestedTarget == .all {
                connectionState = .idle
            } else {
                connectionState = result.hasLocalMedia ? .ready : .idle
            }

            let finalState = RealtimeState(
                connectionState: connectionState,
                sessionID: pending.sessionID ?? state.sessionID,
                reason: requestedTarget.retainsConnection ? nil : pending.reason
            )

            // Finish internal cleanup before notifying listeners so reentrant termination cannot be overwritten.
            if let activeOperation,
                requestedTarget.affects(activeOperation.kind)
            {
                finish(activeOperation)
            }
            let stateChanged = state != finalState
            let listener = stateChanged ? stateListener : nil
            state = finalState
            termination = nil
            errorManager.invalidatePendingFailures(target: requestedTarget)

            if stateChanged, let onStateChanged {
                await onStateChanged(finalState)
            }
            if state == finalState, let listener {
                await listener(finalState)
            }
            if let error = pending.error {
                await errorManager.report(error)
            }
            return
        }
    }

    /// Clears the active operation only if it matches the completed record.
    ///
    /// - Parameter operation: The operation that has completed.
    func finish(
        _ operation: Operation
    ) {
        if activeOperation?.id == operation.id {
            activeOperation = nil
        }
        if generationRequest === operation.generationRequest {
            generationRequest = nil
        }
        operation.generationRequest?.finish()
    }

    /// Updates realtime state and notifies the listener only when the value changes.
    ///
    /// - Parameter nextState: The state to publish.
    func setState(
        _ nextState: RealtimeState
    ) async {
        guard state != nextState else {
            return
        }

        state = nextState
        if let onStateChanged {
            await onStateChanged(nextState)
        }
        // The internal hook can suspend while a newer transition commits.
        guard state == nextState else {
            return
        }
        if let stateListener {
            await stateListener(nextState)
        }
    }

    /// Creates a realtime operation cancellation error.
    static func cancelledError() -> XmaxError {
        XmaxError(
            code: .cancelled,
            message: "Realtime operation was cancelled"
        )
    }
}
