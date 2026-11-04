import Foundation
import XCTest
@testable import XmaxSDK

final class RoomCommandControllerTests: XCTestCase {
    func testMissingAckRetriesFrozenPayloadWithoutBlockingInitialSend() async throws {
        let clock = CommandTestClock()
        let recorder = CommandTestTransport()
        let controller = RoomCommandController(sendMessage: recorder.send, sleep: clock.sleep)
        let sent = try await command(controller)
        try await sent.value
        await eventually { clock.waiterCount == 6 }
        XCTAssertEqual(recorder.messages.count, 1)
        for (offset, count) in [(300, 2), (1000, 3), (3000, 4), (3300, 5), (4000, 6)] {
            clock.advance(to: UInt64(offset) * 1_000_000)
            await eventually { recorder.messages.count == count }
        }
        XCTAssertEqual(Set(recorder.messages).count, 1)
        clock.advance(to: 6_000_000_000)
        await eventually { clock.waiterCount == 0 }
        let update = try await command(controller, kind: .changeCondition)
        try await update.value
        XCTAssertEqual(recorder.messages.count, 7)
        await controller.close()
    }

    func testMatchingAckStopsRetriesAndUnknownOrInvalidCountsDoNot() async throws {
        let clock = CommandTestClock()
        let recorder = CommandTestTransport()
        let controller = RoomCommandController(sendMessage: recorder.send, sleep: clock.sleep)
        let sent = try await command(controller)
        try await sent.value
        await eventually { clock.waiterCount == 6 }
        let xid = try identifier(recorder.messages[0])
        await controller.acknowledge(xid: "other", count: 1)
        await controller.acknowledge(xid: xid, count: 0)
        clock.advance(to: 300_000_000)
        await eventually { recorder.messages.count == 2 }
        await controller.acknowledge(xid: xid, count: 2)
        await eventually { clock.waiterCount == 0 }
        clock.advance(to: 10_000_000_000)
        XCTAssertEqual(recorder.messages.count, 2)
        await controller.close()
    }

    func testEarlyAckDoesNotCompleteOrCancelPendingOriginalSend() async throws {
        let clock = CommandTestClock()
        let recorder = CommandTestTransport(held: true)
        let controller = RoomCommandController(sendMessage: recorder.send, sleep: clock.sleep)
        let sent = try await command(controller)
        await eventually { recorder.messages.count == 1 && clock.waiterCount == 6 }
        let completed = CommandTestFlag()
        let observer = Task { try await sent.value; completed.set() }
        await controller.acknowledge(xid: try identifier(recorder.messages[0]), count: 1)
        await eventually { clock.waiterCount == 0 }
        XCTAssertFalse(completed.value)
        XCTAssertFalse(recorder.tasks[0].isCancelled)
        recorder.finish()
        try await observer.value
        XCTAssertTrue(completed.value)
        await controller.close()
    }

    func testRetryDeadlineDoesNotFailOrCancelUnresolvedOriginalSend() async throws {
        let clock = CommandTestClock()
        let recorder = CommandTestTransport(held: true)
        let controller = RoomCommandController(sendMessage: recorder.send, sleep: clock.sleep)
        let sent = try await command(controller)
        await eventually { recorder.messages.count == 1 && clock.waiterCount == 6 }
        // Expiration stops redundant work while retaining the original operation.
        clock.advance(to: 6_000_000_000)
        await eventually { clock.waiterCount == 0 }
        XCTAssertFalse(recorder.tasks[0].isCancelled)
        recorder.finish()
        try await sent.value
        await controller.close()
    }

    func testNewerConditionReplacesQueuedConditionWhileStartPreservesOrdering() async throws {
        let recorder = CommandTestTransport(held: true)
        let controller = RoomCommandController(sendMessage: recorder.send)
        let start = try await command(controller)
        await eventually { recorder.messages.count == 1 }
        let old = try await command(controller, kind: .changeCondition, prompt: "old")
        let latest = try await command(controller, kind: .changeCondition, prompt: "new")
        do { try await old.value; XCTFail("Superseded command must cancel") } catch {
            XCTAssertEqual(XmaxError.from(error).code, .cancelled)
        }
        XCTAssertEqual(recorder.messages.count, 1)
        recorder.finish()
        try await start.value
        try await latest.value
        XCTAssertEqual(recorder.messages.count, 2)
        XCTAssertTrue(recorder.messages[1].contains("new"))
        await controller.close()
    }

    func testReplacementStartAndTaskStopCancelObsoleteBackgroundWork() async throws {
        let clock = CommandTestClock()
        let recorder = CommandTestTransport()
        let controller = RoomCommandController(sendMessage: recorder.send, sleep: clock.sleep)
        try await command(controller).value
        try await command(controller, kind: .changeTargetSize).value
        let current = try await command(controller, taskID: "new-task")
        try await current.value
        await eventually { clock.waiterCount == 6 }
        clock.advance(to: 300_000_000)
        await eventually { recorder.messages.count == 4 }
        XCTAssertTrue(recorder.messages.last!.contains("new-task"))
        await controller.cancel(taskID: "new-task")
        await eventually { clock.waiterCount == 0 }
        clock.advance(to: 10_000_000_000)
        XCTAssertEqual(recorder.messages.count, 4)
        await controller.close()
    }

    func testCloseCancelsPendingOriginalAndRejectsLateSubmissions() async throws {
        let recorder = CommandTestTransport(held: true)
        let controller = RoomCommandController(sendMessage: recorder.send)
        let sent = try await command(controller)
        await eventually { recorder.messages.count == 1 }
        await controller.close()
        do { try await sent.value; XCTFail("Closed room must cancel") } catch {
            XCTAssertEqual(XmaxError.from(error).code, .cancelled)
        }
        XCTAssertTrue(recorder.tasks[0].isCancelled)
        do { _ = try await command(controller); XCTFail("Closed room must reject late work") } catch {
            XCTAssertEqual(XmaxError.from(error).code, .cancelled)
        }
    }

    func testInitialFailurePropagatesButRetryFailuresDoNotFailGeneration() async throws {
        let clock = CommandTestClock()
        let recorder = CommandTestTransport()
        let controller = RoomCommandController(sendMessage: recorder.send, sleep: clock.sleep)
        recorder.fail = true
        let failed = try await command(controller)
        do { try await failed.value; XCTFail("Initial failure must propagate") } catch {
            XCTAssertEqual(XmaxError.from(error).code, .rtcError)
        }
        recorder.fail = false
        try await command(controller).value
        await eventually { clock.waiterCount == 6 }
        recorder.fail = true
        clock.advance(to: 300_000_000)
        await eventually { recorder.messages.count == 3 }
        clock.advance(to: 1_000_000_000)
        await eventually { recorder.messages.count == 4 }
        recorder.fail = false
        try await command(controller, kind: .changeCondition).value
        await controller.close()
    }

    func testEachControlRelaysFrozenPayloadOnceWhileRTCRetries() async throws {
        for kind in [RoomCommandController.Kind.start, .changeCondition, .changeTargetSize] {
            let clock = CommandTestClock()
            let rtc = CommandTestTransport()
            let http = CommandTestRelay()
            let controller = RoomCommandController(sendMessage: rtc.send, sleep: clock.sleep, relayMessage: http.send)
            try await command(controller, kind: kind).value
            await eventually { http.completed == 1 && clock.waiterCount == 6 }
            for (offset, count) in [(300, 2), (1000, 3), (3000, 4), (3300, 5), (4000, 6)] {
                clock.advance(to: UInt64(offset) * 1_000_000)
                await eventually { rtc.messages.count == count }
            }
            clock.advance(to: 6_000_000_000)
            await eventually { clock.waiterCount == 0 }
            XCTAssertEqual(http.messages, [try XCTUnwrap(rtc.messages.first)])
            XCTAssertEqual(Set(rtc.messages).count, 1)
            await controller.close()
        }
    }

    func testHTTPCompletionDoesNotCompleteRTCOrStopRetries() async throws {
        let clock = CommandTestClock()
        let rtc = CommandTestTransport(held: true)
        let http = CommandTestRelay()
        let completed = CommandTestFlag()
        let controller = RoomCommandController(sendMessage: rtc.send, sleep: clock.sleep, relayMessage: http.send)
        let sent = try await command(controller)
        let observer = Task { try await sent.value; completed.set() }
        await eventually { http.completed == 1 && clock.waiterCount == 6 }
        XCTAssertFalse(completed.value)
        clock.advance(to: 300_000_000)
        await eventually { rtc.messages.count == 2 }
        XCTAssertFalse(completed.value)
        rtc.finish()
        try await observer.value
        await controller.close()
    }

    func testHTTPFailureLeavesRTCResultAndRetriesUnchanged() async throws {
        let clock = CommandTestClock()
        let rtc = CommandTestTransport()
        let http = CommandTestRelay(failure: XmaxError(code: .networkError, message: "Offline"))
        let controller = RoomCommandController(sendMessage: rtc.send, sleep: clock.sleep, relayMessage: http.send)
        try await command(controller).value
        await eventually { http.completed == 1 && clock.waiterCount == 6 }
        clock.advance(to: 300_000_000)
        await eventually { rtc.messages.count == 2 }
        XCTAssertEqual(http.messages.count, 1)
        await controller.close()
    }

    func testAckAndDeadlineRetainHTTPForTaskCancellation() async throws {
        for receivesAck in [true, false] {
            let clock = CommandTestClock()
            let rtc = CommandTestTransport()
            let http = CommandTestRelay(held: true)
            let controller = RoomCommandController(sendMessage: rtc.send, sleep: clock.sleep, relayMessage: http.send)
            try await command(controller).value
            await eventually { http.messages.count == 1 && clock.waiterCount == 6 }
            if receivesAck {
                await controller.acknowledge(xid: try identifier(rtc.messages[0]), count: 1)
            } else {
                clock.advance(to: 6_000_000_000)
            }
            await eventually { clock.waiterCount == 0 }
            XCTAssertEqual(http.cancelled, 0)
            await controller.cancel(taskID: "task")
            await eventually { http.cancelled == 1 }
            await controller.close()
        }
    }

    func testReplacementAndCloseCancelHTTPAfterRTCReceipt() async throws {
        for kind in [RoomCommandController.Kind.start, .changeCondition, .changeTargetSize] {
            let clock = CommandTestClock()
            let rtc = CommandTestTransport()
            let http = CommandTestRelay(held: true)
            let controller = RoomCommandController(sendMessage: rtc.send, sleep: clock.sleep, relayMessage: http.send)
            try await command(controller, kind: kind).value
            await eventually { http.messages.count == 1 }
            await controller.acknowledge(xid: try identifier(rtc.messages[0]), count: 1)
            try await command(controller, kind: kind, prompt: "replacement").value
            await eventually { http.messages.count == 2 && http.cancelled == 1 }
            await controller.close()
            await eventually { http.cancelled == 2 }
        }
    }

    func testAckBeforeRTCCompletionRetainsHTTPForClose() async throws {
        let rtc = CommandTestTransport(held: true)
        let http = CommandTestRelay(held: true)
        let controller = RoomCommandController(sendMessage: rtc.send, relayMessage: http.send)
        let sent = try await command(controller)
        await eventually { http.messages.count == 1 && rtc.messages.count == 1 }
        await controller.acknowledge(xid: try identifier(rtc.messages[0]), count: 1)
        rtc.finish()
        try await sent.value
        XCTAssertEqual(http.cancelled, 0)
        await controller.close()
        await eventually { http.cancelled == 1 }
    }

    func testInitialRTCFailureCancelsIndependentHTTPRequest() async throws {
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        let http = CommandTestRelay(held: true)
        let controller = RoomCommandController(
            sendMessage: { _ in Task { for try await _ in stream {} } },
            relayMessage: http.send
        )
        let sent = try await command(controller)
        await eventually { http.messages.count == 1 }
        let failure = XmaxError(code: .rtcError, message: "Send failed")
        continuation.finish(throwing: failure)
        do { try await sent.value; XCTFail("Initial RTC failure must propagate") }
        catch { XCTAssertEqual(error as? XmaxError, failure) }
        await eventually { http.cancelled == 1 }
        await controller.close()
    }

    private func command(
        _ controller: RoomCommandController,
        kind: RoomCommandController.Kind = .start,
        taskID: String = "task",
        prompt: String = "prompt"
    ) async throws -> Task<Void, any Error> {
        try await controller.send(kind: kind, taskID: taskID) { xid in
            "{\"event\":\"\(kind.rawValue)\",\"uid\":\"\(taskID)\",\"xid\":\"\(xid)\",\"prompt\":\"\(prompt)\"}"
        }
    }

    private func identifier(_ message: String) throws -> String {
        try XCTUnwrap((JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])?["xid"] as? String)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

/// A manual monotonic sleeper that tests can advance without waiting for real retry deadlines.
final class CommandTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    private var waiters: [UUID: (UInt64, CheckedContinuation<Void, any Error>)] = [:]
    var waiterCount: Int { lock.withLock { waiters.count } }

    func sleep(_ delay: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    waiters[id] = (now + delay, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waiters.removeValue(forKey: id)?.1 }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(to value: UInt64) {
        let ready = lock.withLock {
            now = value
            let due = waiters.filter { $0.value.0 <= value }
            for id in due.keys { waiters.removeValue(forKey: id) }
            return due.values.map(\.1)
        }
        ready.forEach { $0.resume() }
    }
}

private final class CommandTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

private final class CommandTestTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Bool
    private var failed = false
    private var stored: [String] = []
    private var active: [Task<Void, any Error>] = []
    private var gates: [AsyncThrowingStream<Void, any Error>.Continuation] = []
    init(held: Bool = false) { self.held = held }
    var messages: [String] { lock.withLock { stored } }
    var tasks: [Task<Void, any Error>] { lock.withLock { active } }
    var fail: Bool {
        get { lock.withLock { failed } }
        set { lock.withLock { failed = newValue } }
    }
    func send(_ message: String) throws -> Task<Void, any Error> {
        lock.withLock {
            stored.append(message)
            let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
            if held { gates.append(continuation) } else { continuation.finish() }
            let shouldFail = failed
            let task = Task {
                if shouldFail { throw XmaxError(code: .rtcError, message: "send failed") }
                for try await _ in stream {}
                try Task.checkCancellation()
            }
            active.append(task)
            return task
        }
    }
    func finish() {
        let values = lock.withLock {
            held = false
            let values = gates
            gates.removeAll()
            return values
        }
        values.forEach { $0.finish() }
    }
}

private final class CommandTestRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let held: Bool
    private let failure: XmaxError?
    private var storedMessages: [String] = []
    private var completedCount = 0
    private var cancelledCount = 0

    init(held: Bool = false, failure: XmaxError? = nil) {
        self.held = held
        self.failure = failure
    }

    var messages: [String] { lock.withLock { storedMessages } }
    var completed: Int { lock.withLock { completedCount } }
    var cancelled: Int { lock.withLock { cancelledCount } }

    func send(_ message: String) async throws {
        lock.withLock { storedMessages.append(message) }
        defer {
            lock.withLock {
                completedCount += 1
                if Task.isCancelled { cancelledCount += 1 }
            }
        }
        if let failure { throw failure }
        if held { try await Task.sleep(nanoseconds: 30_000_000_000) }
    }
}
