//
//  RoomController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages RTC room lifecycle, heartbeat, and generation signaling.
actor RoomController: RoomControlling {

    /// The RTC manager.
    private let rtcManager: any RtcManaging

    /// The room signaling heartbeat.
    private let heartbeat: RoomHeartbeat

    /// The shared startup timing recorder.
    private let timing: RealtimeTiming

    /// The room connection phase.
    private var state = State.idle

    /// The shared pending room leave operation.
    private var leaveOperation: LeaveOperation?

    /// Handles logical retries independently of the RTC packet queue.
    private var commands: RoomCommandController

    /// The retry clock retained when a new room gets a fresh scheduler.
    private let commandSleep: @Sendable (UInt64) async throws -> Void

    /// Whether generation controls use background RTC retries and HTTP relay.
    private let redundantSignalingEnabled: Bool

    /// Submits one HTTP copy of each generation control for the current session.
    private let relayMessage: (@Sendable (String) async throws -> Void)?

    /// Decodes receipts and provider fragments on the room actor.
    private var decoder = RoomMessageDecoder()

    /// Rejects messages captured before a leave or reconnect boundary.
    private var roomOperationID: UUID?

    /// The expected service sender assigned by the session.
    private var botID: String?

    /// The application listener for decoded messages from the current room.
    private var messageListener: RealtimeRoomMessageListener?

    /// Creates a room controller with its default heartbeat.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC manager.
    ///   - timing: The shared startup timing recorder.
    ///   - redundantSignalingEnabled: Whether to retry and relay generation controls.
    init(
        rtcManager: any RtcManaging,
        timing: RealtimeTiming = RealtimeTiming(),
        commandSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        redundantSignalingEnabled: Bool = true,
        relayMessage: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.rtcManager = rtcManager
        self.commandSleep = commandSleep
        self.redundantSignalingEnabled = redundantSignalingEnabled
        self.relayMessage = relayMessage
        commands = Self.makeCommands(
            rtcManager: rtcManager,
            sleep: commandSleep,
            redundantSignalingEnabled: redundantSignalingEnabled,
            relayMessage: relayMessage
        )
        heartbeat = RoomHeartbeat(rtcManager: rtcManager)
        self.timing = timing
    }

    /// Creates a room controller with a heartbeat dependency.
    init(
        rtcManager: any RtcManaging,
        heartbeat: RoomHeartbeat,
        timing: RealtimeTiming = RealtimeTiming(),
        commandSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        redundantSignalingEnabled: Bool = true,
        relayMessage: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.rtcManager = rtcManager
        self.commandSleep = commandSleep
        self.redundantSignalingEnabled = redundantSignalingEnabled
        self.relayMessage = relayMessage
        commands = Self.makeCommands(
            rtcManager: rtcManager,
            sleep: commandSleep,
            redundantSignalingEnabled: redundantSignalingEnabled,
            relayMessage: relayMessage
        )
        self.heartbeat = heartbeat
        self.timing = timing
    }

    /// Joins a realtime room while checking operation validity.
    ///
    /// - Parameters:
    ///   - connection: The server-assigned RTC credentials.
    ///   - ensureActive: The connection validity check.
    ///
    /// - Throws: An error if state is invalid, room join fails or times out, or the call is
    ///   cancelled.
    func join(
        connection: RealtimeSessionConnection,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws {
        do {
            try ensureActive()
        } catch {
            throw XmaxError.from(error)
        }
        guard case .idle = state, leaveOperation == nil else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Leave the current RTC room before joining another one"
            )
        }

        let operationID = UUID()
        commands = Self.makeCommands(
            rtcManager: rtcManager,
            sleep: commandSleep,
            redundantSignalingEnabled: redundantSignalingEnabled,
            relayMessage: relayMessage
        )
        state = .joining(id: operationID)
        heartbeat.stop()

        do {
            timing.beginRoomJoin()
            try await rtcManager.joinRoom(
                configuration: RoomJoinConfiguration(
                    roomID: connection.roomID,
                    userID: connection.userID,
                    token: connection.token
                )
            )
            timing.finishRoomJoin()
            try ensureActive()
            guard case .joining(let currentID) = state,
                currentID == operationID,
                leaveOperation == nil
            else {
                throw XmaxError(
                    code: .cancelled,
                    message: "RTC room join was cancelled"
                )
            }

            state = .joined(userID: connection.userID)
            roomOperationID = operationID
            botID = connection.botName
            rtcManager.setRoomMessageListener { [weak self] sender, data in
                Task {
                    await self?.handleIncomingMessage(
                        sender: sender,
                        data: data,
                        operationID: operationID
                    )
                }
            }
            heartbeat.start(userID: connection.userID)
        } catch {
            if case .joining(let currentID) = state,
                currentID == operationID,
                leaveOperation == nil
            {
                state = .leaving
                heartbeat.stop()
                await rtcManager.leaveRoom()
                if case .leaving = state {
                    state = .idle
                }
            }

            throw XmaxError.from(error)
        }
    }

    /// Stops the heartbeat and leaves the RTC room.
    func leave() async {
        if let leaveOperation {
            await leaveOperation.task.value
            return
        }
        guard state.hasRoomResources else {
            return
        }

        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.performLeave(operationID: operationID)
        }

        leaveOperation = LeaveOperation(
            id: operationID,
            task: task
        )
        await task.value
    }

    /// Enqueues a generation start signal.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve input aspect ratio within the canvas.
    ///
    /// - Throws: An error if the room is not ready or signaling encoding or enqueueing fails.
    func startGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) async throws {
        let userID = try requireUserID()
        let sending = try await commands.send(
            kind: .start,
            taskID: taskID,
            createMessage: { xid in
                try RoomEvent.start(
                    userID: userID,
                    taskID: taskID,
                    videoFormat: videoFormat,
                    targetSize: targetSize,
                    context: context,
                    faceRestoration: faceRestoration,
                    paddingContain: paddingContain,
                    xid: xid
                )
            }
        )
        try await waitForCommand(sending)
    }

    /// Enqueues a generation condition update.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve input aspect ratio within the canvas.
    ///
    /// - Throws: An error if the room is not ready, the call is cancelled, or encoding or
    ///   enqueueing fails.
    func changeGenerationCondition(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) async throws {
        try Task.checkCancellation()
        let userID = try requireUserID()
        let sending = try await commands.send(
            kind: .changeCondition,
            taskID: taskID,
            createMessage: { xid in
                try RoomEvent.changeCondition(
                    userID: userID,
                    taskID: taskID,
                    videoFormat: videoFormat,
                    targetSize: targetSize,
                    context: context,
                    faceRestoration: faceRestoration,
                    paddingContain: paddingContain,
                    xid: xid
                )
            }
        )
        try await waitForCommand(sending)
    }

    /// Changes the active generation task's returned dimensions.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier.
    ///   - targetSize: The integer returned pixel dimensions.
    ///   - ensureActive: The configuration validity check before sending.
    ///
    /// - Throws: An error if cancelled, the room is not ready, or signaling fails.
    func changeTargetSize(
        taskID: String,
        targetSize: CGSize,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws {
        try ensureActive()
        let userID = try requireUserID()
        let sending = try await commands.send(
            kind: .changeTargetSize,
            taskID: taskID,
            createMessage: { xid in
                try RoomEvent.changeTargetSize(
                    userID: userID,
                    taskID: taskID,
                    targetSize: targetSize,
                    xid: xid
                )
            },
            ensureCurrent: ensureActive
        )
        try await waitForCommand(sending)
    }

    /// Sends a stop signal if the room and task are active.
    ///
    /// - Parameter taskID: The generation task to stop.
    ///
    /// - Throws: An error if stop signaling cannot be encoded, enqueued, or sent.
    func stopGeneration(
        taskID: String
    ) async throws {
        await cancelGenerationCommands(taskID: taskID)
        guard !taskID.isEmpty,
            case .joined(let userID) = state
        else {
            return
        }

        let sending = try send(
            RoomEvent.stop(
                userID: userID,
                taskID: taskID
            ),
            discardPending: true
        )
        // A cancelled start can still need to stop the task it already submitted.
        try await sending.value
    }

    /// Submits a generation task's trajectory.
    ///
    /// - Parameters:
    ///   - taskID: The receiving task identifier. Empty identifiers are ignored.
    ///   - points: The normalized media points in `[0, 1]`. Empty arrays are ignored.
    ///
    /// - Throws: An error if the room is not ready or trajectory encoding or enqueueing fails.
    func sendTracks(
        taskID: String,
        points: [RealtimePoint]
    ) throws {
        try Task.checkCancellation()
        guard !taskID.isEmpty, !points.isEmpty else {
            return
        }

        try send(
            RoomEvent.tracks(
                userID: try requireUserID(),
                taskID: taskID,
                points: points
            ),
            replacingPendingMessage: "tracks:\(taskID)"
        )
    }
    /// Cancels old command attempts before media cleanup can suspend.
    func cancelGenerationCommands(taskID: String) async {
        await commands.cancel(taskID: taskID.isEmpty ? nil : taskID)
    }

    func setRoomMessageListener(_ listener: RealtimeRoomMessageListener?) {
        messageListener = listener
    }

    /// Logs current-room events and processes command receipts from the expected generation user.
    private func handleIncomingMessage(sender: String, data: Data, operationID: UUID) async {
        guard roomOperationID == operationID, case .joined(let userID) = state,
            sender != userID
        else { return }

        let expectedSender = botID == nil || sender == botID
        guard expectedSender || messageListener != nil || XmaxLogger.isEnabled(.business),
            let (message, payload) = decoder.decode(sender: sender, data: data)
        else { return }

        XmaxLogger.room.info(message: Self.formatSignalLog(payload, direction: .inbound))
        if let event = message.event {
            messageListener?(RealtimeRoomMessage(
                senderUserID: sender,
                isFromGenerationService: botID == sender,
                event: event,
                taskID: message.taskID,
                payload: payload
            ))
        }

        guard expectedSender,
            message.targetUserID == nil || message.targetUserID == userID,
            message.event == "xid_ack", let xid = message.xid, let count = message.count
        else { return }
        await commands.acknowledge(xid: xid, count: count)
    }

    /// Forwards caller cancellation to unsent fragments and scheduled retries.
    private func waitForCommand(_ sending: Task<Void, any Error>) async throws {
        do {
            try await withTaskCancellationHandler {
                try await RtcMessageQueue.waitForCompletion(of: sending)
            } onCancel: {
                sending.cancel()
            }
        } catch is CancellationError {
            throw XmaxError(code: .cancelled, message: "RTC command was cancelled")
        }
    }

}

extension RoomController {

    /// Creates independent command state for each joined room lifetime.
    fileprivate static func makeCommands(
        rtcManager: any RtcManaging,
        sleep: @escaping @Sendable (UInt64) async throws -> Void,
        redundantSignalingEnabled: Bool,
        relayMessage: (@Sendable (String) async throws -> Void)?
    ) -> RoomCommandController {
        RoomCommandController(
            sendMessage: { message in
                XmaxLogger.room.debug(message: Self.formatSignalLog(Data(message.utf8), direction: .outbound))
                rtcManager.discardPendingMessages(key: nil)
                return try rtcManager.sendRoomMessage(message, reportFailure: false)
            },
            sleep: sleep,
            redundantSignalingEnabled: redundantSignalingEnabled,
            relayMessage: relayMessage
        )
    }

    /// The room connection or leave phase.
    fileprivate enum State {

        /// The room has not been joined.
        case idle

        /// The room is joining with an operation identifier.
        case joining(id: UUID)

        /// The room is joined with a local user identifier.
        case joined(userID: String)

        /// The room is leaving.
        case leaving

        /// Whether the phase retains room resources requiring cleanup.
        var hasRoomResources: Bool {
            switch self {
            case .idle, .leaving:
                false
            case .joining, .joined:
                true
            }
        }
    }

    /// A leave task shared by concurrent callers.
    fileprivate struct LeaveOperation {

        /// The leave operation identifier.
        let id: UUID

        /// The shared leave task.
        let task: Task<Void, Never>
    }

    /// Stops the heartbeat and completes the current room leave.
    ///
    /// - Parameter operationID: The leave operation identifier to validate.
    fileprivate func performLeave(
        operationID: UUID
    ) async {
        state = .idle
        roomOperationID = nil
        botID = nil
        rtcManager.setRoomMessageListener(nil)
        decoder.reset()
        await commands.close()
        heartbeat.stop()
        await rtcManager.leaveRoom()

        if leaveOperation?.id == operationID {
            leaveOperation = nil
        }
    }

    /// Submits room signaling and logs its contents.
    ///
    /// - Parameters:
    ///   - message: The complete JSON room message.
    ///   - reportFailure: Whether asynchronous send failure triggers the RTC failure handler.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///   - discardPending: Whether to first discard unsent trajectories.
    ///
    /// - Returns: The message's send task.
    ///
    /// - Throws: An SDK error if signaling submission fails.
    @discardableResult
    fileprivate func send(
        _ message: String,
        reportFailure: Bool = true,
        replacingPendingMessage key: String? = nil,
        discardPending: Bool = false
    ) throws -> Task<Void, any Error> {
        let sending: Task<Void, any Error>
        do {
            if discardPending {
                rtcManager.discardPendingMessages(key: nil)
            }
            sending = try rtcManager.sendRoomMessage(
                message,
                reportFailure: reportFailure,
                replacingPendingMessage: key
            )
        } catch {
            throw XmaxError.from(error)
        }

        XmaxLogger.room.debug(
            message: Self.formatSignalLog(Data(message.utf8), direction: .outbound)
        )
        return sending
    }

    enum SignalDirection: String {
        case inbound = "接收房间信令 (Inbound Room Signaling)"
        case outbound = "发送房间信令 (Outbound Room Signaling)"
    }

    /// Formats the event and its JSON using the same layout for incoming and outgoing signals.
    static func formatSignalLog(
        _ payload: Data,
        direction: SignalDirection
    ) -> String {
        let contentLabel = XmaxLogger.localized("内容：", "Content: ")
        guard let object = try? JSONSerialization.jsonObject(with: payload),
            let event = object as? [String: Any],
            let formattedData = try? JSONSerialization.data(
                withJSONObject: direction == .inbound ? redactSignalCredentials(event) : event,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let formattedMessage = String(
                data: formattedData,
                encoding: .utf8
            )
        else {
            let content = direction == .outbound ? String(decoding: payload, as: UTF8.self) : "{}"
            return "\(direction.rawValue)\n└─ \(contentLabel)\(content)"
        }

        let eventType = event["event"] as? String ?? "unknown"
        let indentedMessage = formattedMessage.replacingOccurrences(
            of: "\n",
            with: "\n   "
        )
        return "\(direction.rawValue)\n"
            + "├─ \(XmaxLogger.localized("类型：", "Type: "))\(eventType)\n"
            + "└─ \(contentLabel)\n" + "   \(indentedMessage)"
    }

    /// Redacts credential fields in incoming JSON before it reaches the business log.
    private static func redactSignalCredentials(_ value: Any) -> Any {
        if let fields = value as? [String: Any] {
            return fields.reduce(into: [String: Any]()) { result, field in
                let key = field.key.lowercased().filter(\.isLetter)
                let isCredential = key == "authorization" || key.hasSuffix("apikey")
                    || key.hasSuffix("token") || key.hasSuffix("secret") || key.hasSuffix("password")
                result[field.key] = isCredential ? "[REDACTED]" : redactSignalCredentials(field.value)
            }
        }
        if let items = value as? [Any] {
            return items.map(redactSignalCredentials)
        }
        return value
    }

    /// Returns the connected room's local account.
    ///
    /// - Returns: The local RTC account.
    ///
    /// - Throws: An error if the room is not connected.
    fileprivate func requireUserID() throws -> String {
        guard case .joined(let userID) = state else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC room is not joined"
            )
        }
        return userID
    }
}
