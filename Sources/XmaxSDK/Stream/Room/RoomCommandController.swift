//
//  RoomCommandController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Coordinates RTC retries and one HTTP copy independently of generation readiness.
actor RoomCommandController {

    /// Commands with service receipts and a bounded background retry schedule.
    enum Kind: String, Sendable {
        /// Starts a generation task.
        case start
        /// Updates generation conditions.
        case changeCondition = "change_condition"
        /// Updates returned video dimensions.
        case changeTargetSize = "change_target_size"
    }

    /// State accessed only by this controller's actor, including asynchronous attempt completions.
    private final class Command: @unchecked Sendable {
        /// The logical generation operation.
        let kind: Kind
        /// The generation task owning this command.
        let taskID: String
        /// The identifier shared by the original and every redundant attempt.
        let xid: String
        /// The immutable serialized payload retained until cancellation or receipt.
        let message: String
        /// Rejects obsolete configuration before sending or accepting a receipt.
        let ensureCurrent: @Sendable () throws -> Void
        /// Completes only on transport success, initial failure, or explicit cancellation.
        let completion: AsyncThrowingStream<Void, any Error>.Continuation
        /// The caller-visible result independent of the receipt deadline.
        let result: Task<Void, any Error>
        /// The redundant-send timers and final deadline.
        var scheduled: [Task<Void, Never>] = []
        /// Native attempts retained so queued fragments can be cancelled.
        var transports: [UUID: (initial: Bool, task: Task<Void, any Error>)] = [:]
        /// The HTTP submission retained until completion or explicit lifecycle cancellation.
        var relayTask: Task<Void, Never>?
        /// The number of attempts submitted to the transport.
        var attempts = 0
        /// Whether further redundant attempts may be submitted.
        var retrying = true
        /// Whether any complete attempt has succeeded.
        var sent = false
        /// Whether a lifecycle or supersession boundary invalidated the command.
        var cancelled = false

        /// Creates one frozen logical command and its caller completion.
        init(
            kind: Kind,
            taskID: String,
            xid: String,
            message: String,
            ensureCurrent: @escaping @Sendable () throws -> Void,
            completion: AsyncThrowingStream<Void, any Error>.Continuation,
            result: Task<Void, any Error>
        ) {
            self.kind = kind
            self.taskID = taskID
            self.xid = xid
            self.message = message
            self.ensureCurrent = ensureCurrent
            self.completion = completion
            self.result = result
        }
    }

    /// Submits one complete, independently cancellable transport attempt.
    private let sendMessage: @Sendable (String) throws -> Task<Void, any Error>

    /// Submits one independently cancellable HTTP copy of the complete command.
    private let relayMessage: (@Sendable (String) async throws -> Void)?

    /// Sleeps relative to the first attempt; injectable for deterministic retry tests.
    private let sleep: @Sendable (UInt64) async throws -> Void

    /// Commands with pending RTC or HTTP work, indexed by their shared identifier.
    private var pending: [String: Command] = [:]

    /// Orders initial commands without waiting for their receipts or retry budgets.
    private var sendTail: Task<Void, Never>?

    /// Rejects submissions captured across the room's asynchronous leave boundary.
    private var closed = false

    /// Creates a command scheduler without depending on a vendor RTC implementation.
    init(
        sendMessage: @escaping @Sendable (String) throws -> Task<Void, any Error>,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        relayMessage: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.sendMessage = sendMessage
        self.sleep = sleep
        self.relayMessage = relayMessage
    }

    /// Freezes a new command, cancels superseded work, and returns its first successful send.
    func send(
        kind: Kind,
        taskID: String,
        createMessage: @Sendable (String) throws -> String,
        ensureCurrent: @escaping @Sendable () throws -> Void = {}
    ) throws -> Task<Void, any Error> {
        guard !closed else {
            throw XmaxError(code: .cancelled, message: "RTC command room is closed")
        }
        try ensureCurrent()
        let xid = UUID().uuidString
        let message = try createMessage(xid)
        cancelMatching { kind == .start || ($0.taskID == taskID && $0.kind == kind) }
        let (stream, completion) = AsyncThrowingStream<Void, any Error>.makeStream()
        let result = Task {
            try await withTaskCancellationHandler {
                for try await _ in stream {}
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancel(xid: xid) }
            }
        }
        let command = Command(
            kind: kind,
            taskID: taskID,
            xid: xid,
            message: message,
            ensureCurrent: ensureCurrent,
            completion: completion,
            result: result
        )
        pending[xid] = command
        let previous = sendTail
        sendTail = Task {
            // A superseded command must still retain the ordering barrier of earlier initial sends.
            await previous?.value
            if !command.cancelled { self.begin(command) }
            _ = await result.result
        }
        return result
    }

    /// Stops only redundant work for a valid service receipt; never completes the original send.
    func acknowledge(xid: String, count: Int) {
        guard count > 0, count <= 9_007_199_254_740_991,
            let command = pending[xid], command.retrying, command.attempts > 0
        else {
            return
        }
        do {
            try command.ensureCurrent()
            XmaxLogger.room.info(
                message: "接收房间信令 (Inbound Room Signaling)\n"
                    + "├─ \(XmaxLogger.localized("类型：", "Type: "))xid_ack\n"
                    + "├─ \(XmaxLogger.localized("命令：", "Command: "))\(command.kind.rawValue)\n"
                    + "├─ xid: \(command.xid)\n"
                    + "├─ count: \(count)\n"
                    + "└─ \(XmaxLogger.localized("发送次数：", "Attempts: "))\(command.attempts)"
            )
            stopRetries(command)
        } catch {
            cancelCommand(command, error: error)
        }
    }

    /// Cancels an ended task, or all room commands before leaving.
    func cancel(taskID: String? = nil) {
        cancelMatching { taskID == nil || $0.taskID == taskID }
        if taskID == nil { sendTail = nil }
    }

    /// Permanently invalidates this scheduler before the native room can be reused.
    func close() {
        closed = true
        cancel()
    }

    /// Cancels one caller's operation when its send wait is interrupted.
    private func cancel(xid: String) {
        if let command = pending[xid] { cancelCommand(command) }
    }

    /// Starts the two background rounds at 0/300/1000 and 3000/3300/4000 ms.
    private func begin(_ command: Command) {
        guard !command.cancelled else { return }
        for delay: UInt64 in [300, 1000, 3000, 3300, 4000, 6000] {
            command.scheduled.append(
                Task {
                    do { try await sleep(delay * 1_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    if delay == 6000 {
                        guard command.retrying else { return }
                        XmaxLogger.room.warn(
                            message:
                                "RTC command ACK not received after 6000 ms; retries stopped: \(command.kind.rawValue), xid: \(command.xid)"
                        )
                        stopRetries(command)
                    } else {
                        attempt(command, initial: false)
                    }
                }
            )
        }
        beginRelay(command)
        attempt(command, initial: true)
    }

    /// Starts one HTTP submission whose lifetime is independent of RTC receipts and retries.
    private func beginRelay(_ command: Command) {
        guard let relayMessage else { return }
        command.relayTask = Task {
            defer {
                command.relayTask = nil
                releaseCompleted(command)
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                try Task.checkCancellation()
                if !command.sent { try command.ensureCurrent() }
                try await relayMessage(command.message)
            } catch {
                guard !Task.isCancelled, !XmaxError.isCancellation(error) else { return }
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                XmaxLogger.room.warn(
                    message: "HTTP 信令转发失败 (HTTP Signaling Relay Failed)\n"
                        + "├─ event: \(command.kind.rawValue), xid: \(command.xid)\n"
                        + "├─ elapsed: \(elapsed) ms\n"
                        + "└─ \(ErrorMessageFormatter.format(error))"
                )
            }
        }
    }

    /// Submits an attempt while retaining cancellation until native sending settles.
    private func attempt(_ command: Command, initial: Bool) {
        guard command.retrying, !command.cancelled else { return }
        do {
            try command.ensureCurrent()
        } catch {
            cancelCommand(command, error: error)
            return
        }
        do {
            command.attempts += 1
            let id = UUID()
            let transport = try sendMessage(command.message)
            command.transports[id] = (initial, transport)
            Task {
                let outcome = await transport.result
                finishAttempt(command, id: id, initial: initial, outcome: outcome)
            }
        } catch {
            finishAttempt(command, id: UUID(), initial: initial, outcome: .failure(error))
        }
    }

    /// Resolves the caller once; retry failures do not fail an already submitted command.
    private func finishAttempt(
        _ command: Command,
        id: UUID,
        initial: Bool,
        outcome: Result<Void, any Error>
    ) {
        command.transports.removeValue(forKey: id)
        guard !command.cancelled else { return }
        switch outcome {
        case .success:
            if !command.sent {
                command.sent = true
                command.completion.finish()
            }
            releaseCompleted(command)
        case .failure(let error):
            if initial, !command.sent {
                failInitial(command, error: error)
            } else if command.retrying, XmaxError.from(error).code != .cancelled {
                XmaxLogger.room.warn(
                    message:
                        "RTC command retry send failed: \(command.kind.rawValue), xid: \(command.xid)"
                )
            }
        }
    }

    /// Preserves initial-send failure and invalidates dependent updates for a failed start.
    private func failInitial(_ command: Command, error: any Error) {
        if command.kind == .start {
            cancelMatching { $0 !== command && $0.taskID == command.taskID }
        }
        cancelCommand(command, error: error)
    }

    /// Releases scheduled and queued retries while preserving an unresolved original send.
    private func stopRetries(_ command: Command) {
        command.retrying = false
        command.scheduled.forEach { $0.cancel() }
        for transport in command.transports.values where !transport.initial || command.sent {
            transport.task.cancel()
        }
        releaseCompleted(command)
    }

    /// Retains HTTP requests after RTC work finishes so later task cleanup can still cancel them.
    private func releaseCompleted(_ command: Command) {
        if command.sent, !command.retrying, command.relayTask == nil {
            pending.removeValue(forKey: command.xid)
        }
    }

    /// Cancels both original and redundant attempts at an explicit task or supersession boundary.
    private func cancelCommand(
        _ command: Command,
        error: any Error = XmaxError(code: .cancelled, message: "RTC command was cancelled")
    ) {
        command.cancelled = true
        stopRetries(command)
        command.transports.values.forEach { $0.task.cancel() }
        command.relayTask?.cancel()
        command.completion.finish(
            throwing: error is CancellationError
                ? XmaxError(code: .cancelled, message: "RTC command was cancelled")
                : XmaxError.from(error)
        )
        pending.removeValue(forKey: command.xid)
    }

    /// Snapshots matches before mutation to safely cancel multiple commands.
    private func cancelMatching(_ matches: (Command) -> Bool) {
        for command in Array(pending.values) where matches(command) { cancelCommand(command) }
    }
}
