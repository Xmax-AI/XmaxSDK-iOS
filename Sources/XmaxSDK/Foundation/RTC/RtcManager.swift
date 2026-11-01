//
//  RtcManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages RTC leases, connection waits, and event validity.
final class RtcManager: RtcManaging, @unchecked Sendable {

    /// The default room join timeout, in nanoseconds.
    static let joinTimeoutNanoseconds: UInt64 = 15000000000

    // MARK: - Dependencies

    /// The exclusive engine lease provider.
    private let engineManager: RtcEngineManager

    /// The provider fixed at manager creation.
    private let provider: RtcProvider

    /// The room join timeout, in nanoseconds.
    private let joinTimeout: UInt64

    // MARK: - State

    /// The lock protecting room, lease, and initialization state.
    private let stateLock = NSLock()

    /// The lock serializing compound RTC operations.
    private let operationLock = NSRecursiveLock()

    /// The engine lease held by this manager.
    private var engineLease: RtcEngineLease?

    /// The active room and its validity.
    private var activeRoom: RoomContext?

    /// The pending room join request.
    private var pendingJoin: PendingJoin?

    /// The listener for room and remote stream events.
    private weak var eventListener: (any RtcEventListener)?

    /// The raw signaling listener, protected by the state lock and current room lifetime.
    private var roomMessageListener: (@Sendable (String, Data) -> Void)?

    /// The listener for RTC quality and media statistics.
    private weak var qualityListener: (any RtcQualityListener)?

    /// The shared engine initialization operation.
    private var initialization: Initialization?

    /// Creates an RTC manager with a room join timeout.
    ///
    /// - Parameters:
    ///   - engineManager: The exclusive engine lease manager.
    ///   - joinTimeoutNanoseconds: The room join timeout, in nanoseconds.
    init(
        engineManager: RtcEngineManager = .shared,
        provider: RtcProvider = .agora,
        joinTimeoutNanoseconds: UInt64 = RtcManager.joinTimeoutNanoseconds
    ) {
        self.engineManager = engineManager
        self.provider = provider
        joinTimeout = joinTimeoutNanoseconds
    }

    /// Acquires an exclusive engine lease and initializes RTC.
    ///
    /// - Throws: An error if lease acquisition is cancelled or initialization fails.
    func initialize() async throws {
        guard !Task.isCancelled else {
            throw Self.cancelledError(operation: "RTC initialization")
        }

        let waiterID = UUID()
        let initialization = stateLock.withLock { () -> Initialization? in
            guard engineLease == nil else {
                return nil
            }
            if var initialization {
                initialization.waiterIDs.insert(waiterID)
                self.initialization = initialization
                return initialization
            }

            let initialization = Initialization(
                id: UUID(),
                task: Task {
                    try await engineManager.acquire(provider: provider)
                },
                waiterIDs: [waiterID]
            )
            self.initialization = initialization
            return initialization
        }

        guard let initialization else {
            return
        }

        do {
            let lease = try await withTaskCancellationHandler {
                try await initialization.task.value
            } onCancel: {
                self.cancelInitializationWaiter(
                    initializationID: initialization.id,
                    waiterID: waiterID
                )
            }

            try await finishInitialization(
                initializationID: initialization.id,
                lease: lease
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            clearInitialization(id: initialization.id)
            throw Self.cancelledError(operation: "RTC initialization")
        } catch {
            clearInitialization(id: initialization.id)
            throw error
        }
    }

    /// Destroys the RTC engine and releases resources.
    func destroy() async {
        await leaveRoom()
        let resources = operationLock.withLock {
            stateLock.withLock { () -> (RtcEngineLease?, Initialization?) in
                let resources = (engineLease, initialization)
                engineLease = nil
                initialization = nil
                return resources
            }
        }

        resources.1?.task.cancel()
        if let lease = resources.0 {
            await engineManager.release(lease)
        }
    }

    /// Applies the uplink encoder configuration.
    ///
    /// - Parameter configuration: The dimensions, frame rate, bitrate, and encoding preference.
    ///
    /// - Throws: An error if the engine rejects the configuration.
    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws {
        guard configuration.width > 0, configuration.height > 0, configuration.frameRate > 0 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video width, height, and frame rate must be positive"
            )
        }
        try withEngine {
            try $0.configureVideoEncoding(configuration)
        }
    }

    /// Enables external video input.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws {
        try withEngine {
            try $0.useExternalVideoSource()
        }
    }

    /// Updates uplink video mirroring.
    ///
    /// - Parameter position: The current camera position.
    ///
    /// - Throws: An error if encoder mirroring cannot be configured.
    func configureLocalVideoMirror(
        for position: CameraPosition
    ) throws {
        try withOptionalEngine {
            try $0.configureLocalVideoMirror(for: position)
        }
    }

    /// Switches to microphone input and starts capture.
    ///
    /// - Throws: An error if source switching or capture fails.
    func startAudioCapture() throws {
        try withEngine {
            try $0.startAudioCapture()
        }
    }

    /// Stops microphone capture.
    ///
    /// - Throws: An error if the engine cannot stop capture.
    func stopAudioCapture() throws {
        try withOptionalEngine {
            try $0.stopAudioCapture()
        }
    }

    /// Enables external PCM input.
    ///
    /// - Throws: An error if the external audio track cannot be created.
    func startExternalAudioSource() throws {
        try withEngine {
            try $0.startExternalAudioSource()
        }
    }

    /// Stops external PCM input and releases its track.
    ///
    /// - Throws: An error if the audio track cannot be released.
    func stopExternalAudioSource() throws {
        try withOptionalEngine {
            try $0.stopExternalAudioSource()
        }
    }

    /// Pushes an external video frame.
    ///
    /// - Parameter frame: The SDK video frame.
    ///
    /// - Throws: An error if the frame format or data is invalid.
    func pushExternalVideoFrame(
        _ frame: VideoFrame
    ) throws {
        try withEngine {
            try $0.pushExternalVideoFrame(frame)
        }
    }

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: A timestamped 10 ms PCM frame.
    ///
    /// - Throws: An error if the frame format or data is invalid.
    func pushExternalAudioFrame(
        _ frame: AudioFrame
    ) throws {
        try withEngine {
            try $0.pushExternalAudioFrame(frame)
        }
    }

    /// Joins an RTC room and waits for connection.
    ///
    /// - Parameter configuration: The room, user identifier, and token.
    ///
    /// - Throws: An error if the engine is unavailable, join fails or times out, or the call is
    ///   cancelled.
    func joinRoom(
        configuration: RoomJoinConfiguration
    ) async throws {
        guard configuration.credentials.provider == provider else {
            throw XmaxError(code: .invalidConfiguration, message: "RTC credentials do not match the selected provider")
        }
        guard !configuration.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !configuration.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC room ID and user account cannot be empty"
            )
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginJoin(
                    id: id,
                    configuration: configuration,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.failPendingJoin(
                id: id,
                error: Self.cancelledError(operation: "RTC join room")
            )
        }
    }

    /// Leaves the active RTC room.
    func leaveRoom() async {
        operationLock.withLock {
            let resources = stateLock.withLock { () -> (RoomContext?, PendingJoin?) in
                let result = (activeRoom, pendingJoin)
                activeRoom = nil
                pendingJoin = nil
                return result
            }

            resources.1?.timeoutTask?.cancel()
            resources.1?.continuation.resume(
                throwing: Self.cancelledError(operation: "RTC join room")
            )
            tearDownRoom(resources.1?.context)
            tearDownRoom(resources.0)
        }
    }

    /// Publishes local video.
    ///
    /// - Throws: An error if the room is unavailable or publication fails.
    func publishLocalVideo() throws {
        try withRoom {
            try $0.publishLocalVideo(true)
        }
    }

    /// Stops local video publication.
    ///
    /// - Throws: An error if the room is unavailable or unpublishing fails.
    func unpublishLocalVideo() throws {
        try withOptionalRoom {
            try $0.publishLocalVideo(false)
        }
    }

    /// Publishes local audio.
    ///
    /// - Throws: An error if the room is unavailable or audio publication fails.
    func publishLocalAudio() throws {
        try withRoom {
            try $0.publishLocalAudio(true)
        }
    }

    /// Stops local audio publication.
    ///
    /// - Throws: An error if the room is unavailable or audio unpublishing fails.
    func unpublishLocalAudio() throws {
        try withOptionalRoom {
            try $0.publishLocalAudio(false)
        }
    }

    /// Changes a remote user's video subscription.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to video.
    ///
    /// - Throws: An error if the room is unavailable, the user cannot be resolved, or subscription
    ///   fails.
    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws {
        try withRoom {
            try $0.subscribeRemoteVideo(
                userID: userID,
                subscribe: subscribe
            )
        }
    }

    /// Changes a remote user's audio subscription.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to audio.
    ///
    /// - Throws: An error if the room is unavailable, the user cannot be resolved, or subscription
    ///   fails.
    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws {
        try withRoom {
            try $0.subscribeRemoteAudio(
                userID: userID,
                subscribe: subscribe
            )
        }
    }

    /// Sets a remote user's playback volume.
    ///
    /// - Parameters:
    ///   - volume: The playback volume, from 0 to 100.
    ///   - userID: The remote RTC user identifier.
    ///
    /// - Throws: An error if the room is unavailable or volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws {
        guard (0...100).contains(volume) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC audio volume must be between 0 and 100"
            )
        }

        try withRoom {
            try $0.setRemoteAudioVolume(
                volume,
                for: userID
            )
        }
    }

    /// Sets a decoded frame listener for a remote stream.
    ///
    /// - Parameters:
    ///   - listener: The decoded frame handler, or `nil` to remove it.
    ///   - stream: The remote stream to observe.
    ///
    /// - Throws: An error if the room is unavailable or the listener cannot be configured.
    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for stream: RemoteStream
    ) throws {
        try operationLock.withLock {
            guard
                let context = stateLock.withLock({
                    activeRoom
                }), context.roomID == stream.roomID
            else {
                if listener == nil {
                    return
                }
                throw XmaxError(
                    code: .rtcError,
                    message: "Remote stream is unavailable"
                )
            }

            let id = context.id
            let guardedListener: RtcRemoteVideoFrameListener?
            if let listener {
                guardedListener = { [weak self] frame in
                    guard let self,
                        self.stateLock.withLock({
                            self.activeRoom?.id == id
                        })
                    else {
                        return
                    }
                    listener(frame)
                }
            } else {
                guardedListener = nil
            }

            try context.room.setRemoteVideoFrameListener(
                guardedListener,
                for: stream.userID
            )
        }
    }

    /// Sets a remote PCM listener guarded by the current room's connection lifetime.
    ///
    /// - Parameters:
    ///   - listener: The owned audio handler, or `nil` to remove it.
    ///   - stream: The remote result stream.
    ///
    /// - Throws: An error if the room or remote account is unavailable.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for stream: RemoteStream
    ) throws {
        try operationLock.withLock {
            guard let context = stateLock.withLock({ activeRoom }),
                  context.roomID == stream.roomID
            else {
                if listener == nil {
                    return
                }
                throw XmaxError(
                    code: .rtcError,
                    message: "Remote audio stream is unavailable"
                )
            }

            let id = context.id
            let guardedListener: RtcRemoteAudioFrameListener?
            if let listener {
                guardedListener = { [weak self] frame in
                    guard let self, stateLock.withLock({ activeRoom?.id == id }) else {
                        return
                    }
                    listener(frame)
                }
            } else {
                guardedListener = nil
            }

            try context.room.setRemoteAudioFrameListener(
                guardedListener,
                for: stream.userID
            )
        }
    }

    /// Sends a message to the active RTC room.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failures are reported as room failures.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///
    /// - Returns: The task for awaiting this message's send result.
    ///
    /// - Throws: An error if enqueueing fails.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool = true,
        replacingPendingMessage key: String? = nil
    ) throws -> Task<Void, any Error> {
        try withRoom {
            try $0.sendRoomMessage(
                message,
                reportFailure: reportFailure,
                replacingPendingMessage: key
            )
        }
    }

    /// Drops coalescible messages not yet sent by the active room.
    ///
    /// - Parameter key: The coalescing key, or `nil` for all coalescible messages.
    func discardPendingMessages(
        key: String?
    ) {
        operationLock.withLock {
            let room = stateLock.withLock {
                activeRoom?.room
            }
            room?.discardPendingMessages(key: key)
        }
    }

    /// Waits for queued room signaling to finish.
    ///
    /// - Throws: An error if the room is unavailable, sending fails, or waiting is cancelled.
    func awaitPendingMessages() async throws {
        let room = try operationLock.withLock {
            try requireRoom().room
        }
        try await room.awaitPendingMessages()
    }

    /// Sets the RTC connection and media event listener.
    ///
    /// - Parameter listener: The event listener, or `nil` to remove it.
    func setEventListener(
        _ listener: (any RtcEventListener)?
    ) {
        stateLock.withLock {
            eventListener = listener
        }
    }

    /// Replaces the signaling callback without requiring the main actor.
    func setRoomMessageListener(
        _ listener: (@Sendable (String, Data) -> Void)?
    ) {
        stateLock.withLock { roomMessageListener = listener }
    }

    /// Sets the RTC network and media quality listener.
    ///
    /// - Parameter listener: The quality listener, or `nil` to remove it.
    func setQualityListener(
        _ listener: (any RtcQualityListener)?
    ) {
        stateLock.withLock {
            qualityListener = listener
        }
    }
}

private extension RtcManager {

    /// A shared initialization task and its waiting callers.
    struct Initialization {

        /// The initialization revision identifier.
        let id: UUID

        /// The shared engine acquisition task.
        let task: Task<RtcEngineLease, any Error>

        /// The callers awaiting this initialization.
        var waiterIDs: Set<UUID>
    }

    /// A platform room and identity isolating events from previous connections.
    final class RoomContext: Sendable {

        /// The connection identifier.
        let id: UUID

        /// The RTC room identifier for this context.
        let roomID: String

        /// The connection's platform room.
        let room: any RtcRoom

        /// Creates a room context.
        init(
            id: UUID,
            roomID: String,
            room: any RtcRoom
        ) {
            self.id = id
            self.roomID = roomID
            self.room = room
        }
    }

    /// A pending room join, including its continuation and timeout.
    final class PendingJoin: @unchecked Sendable {

        /// The room awaiting connection.
        let context: RoomContext

        /// The continuation awaiting room join.
        let continuation: CheckedContinuation<Void, any Error>

        /// The room join timeout task.
        var timeoutTask: Task<Void, Never>?

        /// Creates a pending room join context.
        init(
            context: RoomContext,
            continuation: CheckedContinuation<Void, any Error>
        ) {
            self.context = context
            self.continuation = continuation
        }
    }

    /// Accepts an engine lease if initialization remains current.
    ///
    /// - Parameters:
    ///   - initializationID: The initialization identifier.
    ///   - lease: The newly acquired engine lease.
    ///
    /// - Throws: A cancellation error if initialization was cancelled or replaced.
    func finishInitialization(
        initializationID: UUID,
        lease: RtcEngineLease
    )
        async throws
    {
        let installed = operationLock.withLock {
            stateLock.withLock { () -> Bool in
                if engineLease?.id == lease.id {
                    return true
                }
                guard initialization?.id == initializationID else {
                    return false
                }
                engineLease = lease
                initialization = nil
                return true
            }
        }
        if !installed {
            await engineManager.release(lease)
            throw Self.cancelledError(operation: "RTC initialization")
        }
    }

    /// Removes a waiter and cancels engine acquisition when none remain.
    ///
    /// - Parameters:
    ///   - initializationID: The initialization identifier.
    ///   - waiterID: The waiter to cancel.
    func cancelInitializationWaiter(
        initializationID: UUID,
        waiterID: UUID
    ) {
        let task = stateLock.withLock { () -> Task<RtcEngineLease, any Error>? in
            guard var initialization,
                initialization.id == initializationID,
                initialization.waiterIDs.remove(waiterID) != nil
            else {
                return nil
            }
            guard initialization.waiterIDs.isEmpty else {
                self.initialization = initialization
                return nil
            }

            self.initialization = nil
            return initialization.task
        }

        task?.cancel()
    }

    /// Clears a matching initialization operation.
    ///
    /// - Parameter id: The initialization identifier to clear.
    func clearInitialization(
        id: UUID
    ) {
        stateLock.withLock {
            if initialization?.id == id {
                initialization = nil
            }
        }
    }

    /// Creates a room and begins join with timeout handling.
    ///
    /// - Parameters:
    ///   - id: The connection identifier.
    ///   - configuration: The room and user credentials.
    ///   - continuation: The continuation receiving join success or failure.
    func beginJoin(
        id: UUID,
        configuration: RoomJoinConfiguration,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        operationLock.withLock {
            do {
                try Task.checkCancellation()
                let engine = try requireEngine()
                guard
                    stateLock.withLock({
                        activeRoom == nil && pendingJoin == nil
                    })
                else {
                    throw XmaxError(
                        code: .rtcError,
                        message: "RTC room is already active"
                    )
                }

                let room = try engine.createRoom(roomID: configuration.roomID)
                let context = RoomContext(
                    id: id,
                    roomID: configuration.roomID,
                    room: room
                )
                let pending = PendingJoin(
                    context: context,
                    continuation: continuation
                )
                stateLock.withLock {
                    pendingJoin = pending
                }

                room.setEventListener { [weak self] event in
                    self?.handleRoomEvent(
                        event,
                        id: id
                    )
                }

                pending.timeoutTask = Task { [weak self, joinTimeout] in
                    try? await Task.sleep(nanoseconds: joinTimeout)
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.failPendingJoin(
                        id: id,
                        error: XmaxError(
                            code: .timeout,
                            message: "RTC join room timed out"
                        )
                    )
                }

                try room.join(configuration: configuration)
            } catch {
                if stateLock.withLock({
                    pendingJoin?.context.id == id
                }) {
                    failPendingJoin(
                        id: id,
                        error: XmaxError.from(error)
                    )
                } else {
                    continuation.resume(throwing: XmaxError.from(error))
                }
            }
        }
    }

    /// Handles events from the current connection.
    ///
    /// - Parameters:
    ///   - event: The platform room event.
    ///   - id: The connection that produced the event.
    func handleRoomEvent(
        _ event: RtcRoomEvent,
        id: UUID
    ) {
        operationLock.withLock {
            guard
                let context = stateLock.withLock(
                    {
                        activeRoom?.id == id ? activeRoom : pendingJoin?.context
                    }
                ),
                context.id == id
            else {
                return
            }

            switch event {
            case .joined:
                finishJoin(context)
            case .message(let userID, let data):
                let callback = stateLock.withLock {
                    activeRoom?.id == id ? roomMessageListener : nil
                }
                callback?(userID, data)
            case .publication(
                let userID,
                let published
            ):
                notifyPublication(
                    id: id,
                    userID: userID,
                    published: published
                )
            case .failure(let error):
                failRoom(
                    id: id,
                    error: error
                )
            case .quality(
                let uplink,
                let downlink
            ):
                notifyQuality(id: id) {
                    $0.onNetworkQuality(
                        uplink: uplink,
                        downlink: downlink
                    )
                }
            case .uplinkVideoStatistics(let statistics):
                notifyQuality(id: id) {
                    $0.onUplinkVideoStatistics(statistics)
                }
            case .downlinkVideoStatistics(let statistics):
                notifyQuality(id: id) {
                    $0.onDownlinkVideoStatistics(statistics)
                }
            case .performance(
                let limited,
                let width,
                let height,
                let fps
            ):
                notifyQuality(id: id) {
                    $0.onPerformanceAlarm(
                        limited: limited,
                        suggestedWidth: width,
                        suggestedHeight: height,
                        suggestedFrameRate: fps
                    )
                }
            }
        }
    }

    /// Activates a connected room and completes its join request.
    ///
    /// - Parameter context: The connected room context.
    func finishJoin(
        _ context: RoomContext
    ) {
        guard
            let pending = stateLock.withLock({
                pendingJoin
            }), pending.context === context
        else {
            return
        }

        stateLock.withLock {
            activeRoom = context
            pendingJoin = nil
        }

        pending.timeoutTask?.cancel()
        pending.continuation.resume()
    }

    /// Fails a matching join request and releases its room.
    ///
    /// - Parameters:
    ///   - id: The connection identifier to terminate.
    ///   - error: The error returned to the join caller.
    func failPendingJoin(
        id: UUID,
        error: any Error
    ) {
        operationLock.withLock {
            let pending = stateLock.withLock { () -> PendingJoin? in
                guard pendingJoin?.context.id == id else {
                    return nil
                }
                let value = pendingJoin
                pendingJoin = nil
                return value
            }
            guard let pending else {
                return
            }

            pending.timeoutTask?.cancel()
            tearDownRoom(pending.context)
            pending.continuation.resume(throwing: error)
        }
    }

    /// Reports a connection failure to the join caller or connection listener.
    ///
    /// - Parameters:
    ///   - id: The failed connection identifier.
    ///   - error: The connection failure.
    func failRoom(
        id: UUID,
        error: XmaxError
    ) {
        if stateLock.withLock({
            pendingJoin?.context.id == id
        }) {
            failPendingJoin(
                id: id,
                error: error
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let listener = stateLock.withLock {
                activeRoom?.id == id ? eventListener : nil
            }
            listener?.onRtcFailure(error)
        }
    }

    /// Delivers current video publication changes on the main actor.
    ///
    /// - Parameters:
    ///   - id: The connection identifier.
    ///   - userID: The remote user identifier.
    ///   - published: Whether remote video is published.
    func notifyPublication(
        id: UUID,
        userID: String,
        published: Bool
    ) {
        guard
            stateLock.withLock({
                activeRoom?.id == id
            })
        else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let listener = stateLock.withLock {
                activeRoom?.id == id ? eventListener : nil
            }
            listener?.onRemoteVideoPublished(
                userID: userID,
                published: published
            )
        }
    }

    /// Delivers quality events for the current connection on the main actor.
    ///
    /// - Parameters:
    ///   - id: The connection identifier.
    ///   - action: The quality notification to deliver.
    func notifyQuality(
        id: UUID,
        _ action: @escaping @MainActor @Sendable (any RtcQualityListener) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let listener = stateLock.withLock {
                activeRoom?.id == id ? qualityListener : nil
            }
            if let listener {
                action(listener)
            }
        }
    }

    /// Removes room event handlers and destroys the room.
    ///
    /// - Parameter context: The room to release, or `nil` for no operation.
    func tearDownRoom(
        _ context: RoomContext?
    ) {
        context?.room.setEventListener(nil)
        context?.room.destroy()
    }

    /// Returns the engine held by the active lease.
    ///
    /// - Returns: The current RTC platform engine.
    ///
    /// - Throws: An error if the engine is not initialized.
    func requireEngine() throws -> any RtcPlatform {
        guard
            let engine = stateLock.withLock({
                engineLease?.engine
            })
        else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC engine is not initialized"
            )
        }
        return engine
    }

    /// Returns the connected room context.
    ///
    /// - Returns: The active room context.
    ///
    /// - Throws: An error if no room has been joined.
    func requireRoom() throws -> RoomContext {
        guard
            let context = stateLock.withLock({
                activeRoom
            })
        else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC room is not joined"
            )
        }
        return context
    }

    /// Runs an engine operation under the operation lock.
    ///
    /// - Parameter operation: The synchronous engine operation.
    ///
    /// - Returns: The operation result.
    ///
    /// - Throws: An error if the engine is unavailable or the operation fails.
    func withEngine<T>(
        _ operation: (any RtcPlatform) throws -> T
    ) throws -> T {
        try operationLock.withLock {
            try operation(requireEngine())
        }
    }

    /// Runs an operation if an engine is available.
    ///
    /// - Parameter operation: The engine operation, skipped if no engine exists.
    ///
    /// - Throws: An error if the engine operation fails.
    func withOptionalEngine(
        _ operation: (any RtcPlatform) throws -> Void
    ) throws {
        try operationLock.withLock {
            if let engine = stateLock.withLock({
                engineLease?.engine
            }) {
                try operation(engine)
            }
        }
    }

    /// Runs a room operation under the operation lock.
    ///
    /// - Parameter operation: The synchronous room operation.
    ///
    /// - Returns: The operation result.
    ///
    /// - Throws: An error if the room is unavailable or the operation fails.
    func withRoom<T>(
        _ operation: (any RtcRoom) throws -> T
    ) throws -> T {
        try operationLock.withLock {
            try operation(requireRoom().room)
        }
    }

    /// Runs an operation if an active room is available.
    ///
    /// - Parameter operation: The room operation, skipped if no room exists.
    ///
    /// - Throws: An error if the room operation fails.
    func withOptionalRoom(
        _ operation: (any RtcRoom) throws -> Void
    ) throws {
        try operationLock.withLock {
            if let context = stateLock.withLock({
                activeRoom
            }) {
                try operation(context.room)
            }
        }
    }

    /// Creates an RTC cancellation error.
    ///
    /// - Parameter operation: The cancelled operation's name.
    ///
    /// - Returns: A cancellation error naming the operation.
    static func cancelledError(
        operation: String
    ) -> XmaxError {
        XmaxError(
            code: .cancelled,
            message: "\(operation) was cancelled"
        )
    }
}
