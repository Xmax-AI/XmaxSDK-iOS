//
//  RtcMessageQueueTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

final class RtcMessageQueueTests: XCTestCase {
    func testRecoverableConfigurationFailureDoesNotPoisonNextMessage() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: { data in
            if data == Data("resize".utf8) {
                throw XmaxError(code: .rtcError, message: "resize failed")
            }
            recorder.append(data)
        }, onFailure: { _ in XCTFail("Recoverable configuration must not terminate the room") })
        let resize = try queue.enqueue("resize", reportFailure: false)
        try queue.enqueue("next condition")
        try await queue.flush()
        do {
            try await RtcMessageQueue.waitForCompletion(of: resize)
            XCTFail("A later successful message must not hide the configuration failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.message, "resize failed")
        }
        XCTAssertEqual(recorder.packets, [Data("next condition".utf8)])
        queue.close()
    }

    func testSmallMessageIsSentWithoutEnvelope() throws {
        let message = #"{"event":"heartbeat","user_id":"account"}"#
        XCTAssertEqual(try RtcMessageCodec.encode(message), [Data(message.utf8)])
    }

    func testFragmentedUnicodeAndEscapesRoundTripWithinPacketLimit() throws {
        let message = String(repeating: "中文🙂\\\"\n/", count: 250)
        let packets = try RtcMessageCodec.encode(message)
        XCTAssertGreaterThan(packets.count, 1)
        var result = ""
        var identifier: String?
        for (index, packet) in packets.enumerated() {
            XCTAssertLessThanOrEqual(packet.count, 800)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: packet) as? [String: Any])
            XCTAssertEqual(value["event"] as? String, "__agora_chunk__")
            XCTAssertEqual(value["index"] as? Int, index)
            XCTAssertEqual(value["count"] as? Int, packets.count)
            let currentID = try XCTUnwrap(value["eventId"] as? String)
            if let identifier { XCTAssertEqual(currentID, identifier) }
            identifier = currentID
            result += try XCTUnwrap(value["data"] as? String)
        }
        XCTAssertEqual(result, message)
    }

    func testCodecRejectsEmptyAndOversizedMessages() {
        XCTAssertThrowsError(try RtcMessageCodec.encode(""))
        XCTAssertThrowsError(try RtcMessageCodec.encode(String(repeating: "a", count: 262145)))
    }

    func testQueuePreservesWholeMessageOrderAndFlushes() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: recorder.append, onFailure: { _ in })
        let first = String(repeating: "a", count: 1200)
        try queue.enqueue(first)
        try queue.enqueue("last")
        try await queue.flush()
        XCTAssertEqual(recorder.packets.last, Data("last".utf8))
        XCTAssertEqual(recorder.packets.count, 3)
        queue.close()
        XCTAssertThrowsError(try queue.enqueue("after close"))
    }

    func testQueueRespectsByteRateLimit() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: recorder.append, onFailure: { _ in })
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<37 { try queue.enqueue(String(repeating: "a", count: 800)) }
        try await queue.flush()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertGreaterThanOrEqual(elapsed, 1000000000)
        XCTAssertEqual(recorder.packets.count, 37)
        queue.close()
    }

    func testQueueRespectsPacketRateLimit() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: recorder.append, onFailure: { _ in XCTFail() })
        defer { queue.close() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<59 { try queue.enqueue("a") }
        try await queue.flush()
        XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - start, 1000000000)
        XCTAssertEqual(recorder.packets.count, 59)
    }

    func testBudgetNoLongerUsesLegacyByteLimit() async throws {
        let recorder = PacketRecorder()
        let sent = expectation(description: "30 packets sent within the first window")
        sent.expectedFulfillmentCount = 30
        let queue = RtcMessageQueue(send: {
            recorder.append($0)
            sent.fulfill()
        }, onFailure: { _ in XCTFail() })
        defer { queue.close() }
        for _ in 0..<30 { try queue.enqueue(String(repeating: "a", count: 800)) }
        await fulfillment(of: [sent], timeout: 0.9)
        XCTAssertEqual(recorder.packets.count, 30)
    }

    func testPendingTrajectoryReplacementDoesNotFillQueueOrDropControls() async throws {
        let recorder = PacketRecorder()
        let entered = expectation(description: "start sending")
        let gate = DispatchSemaphore(value: 0)
        let queue = RtcMessageQueue(send: { data in
            recorder.append(data)
            if data == Data("start".utf8) {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
        }, onFailure: { _ in XCTFail() })
        defer { gate.signal(); queue.close() }
        try queue.enqueue("start")
        await fulfillment(of: [entered], timeout: 2)
        for index in 0..<200 {
            try queue.enqueue("position-\(index)", replacingPendingMessage: "tracks:task")
        }
        try queue.enqueue("condition")
        try queue.enqueue("stop")
        gate.signal()
        try await queue.flush()
        XCTAssertEqual(
            recorder.packets,
            ["start", "position-199", "condition", "stop"].map { Data($0.utf8) }
        )
    }

    func testTrajectoryCanBeReplacedWhileWaitingForRateBudget() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: recorder.append, onFailure: { _ in XCTFail() })
        defer { queue.close() }
        for _ in 0..<58 { try queue.enqueue("budget") }
        try await queue.flush()
        try queue.enqueue("old", replacingPendingMessage: "tracks:task")
        try await Task.sleep(nanoseconds: 20000000)
        try queue.enqueue(String(repeating: "new", count: 100), replacingPendingMessage: "tracks:task")
        try await queue.flush()
        XCTAssertEqual(recorder.packets.count, 59)
        XCTAssertEqual(recorder.packets.last, Data(String(repeating: "new", count: 100).utf8))
        XCTAssertFalse(recorder.packets.contains(Data("old".utf8)))
    }

    func testDiscardingTrajectoryKeepsPrecedingAndFollowingControlsOrdered() async throws {
        let recorder = PacketRecorder()
        let entered = expectation(description: "start sending")
        let gate = DispatchSemaphore(value: 0)
        let queue = RtcMessageQueue(send: { data in
            recorder.append(data)
            if data == Data("start".utf8) {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
        }, onFailure: { _ in XCTFail("Discarding a trajectory must not report a room failure") })
        defer { gate.signal(); queue.close() }
        try queue.enqueue("start")
        await fulfillment(of: [entered], timeout: 2)
        try queue.enqueue("old trajectory", replacingPendingMessage: "tracks:old")
        queue.discardPendingMessages()
        try queue.enqueue("stop")
        try queue.enqueue("new generation")
        try queue.enqueue("new trajectory", replacingPendingMessage: "tracks:new")
        gate.signal()
        try await queue.flush()
        XCTAssertEqual(
            recorder.packets,
            ["start", "stop", "new generation", "new trajectory"].map { Data($0.utf8) }
        )
    }

    func testReplacingTrajectoryDoesNotInterruptStartedFragments() async throws {
        let recorder = PacketRecorder()
        let entered = expectation(description: "first fragment sending")
        let gate = DispatchSemaphore(value: 0)
        let queue = RtcMessageQueue(send: { data in
            recorder.append(data)
            if recorder.packets.count == 1 {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
        }, onFailure: { _ in XCTFail() })
        defer { gate.signal(); queue.close() }
        try queue.enqueue(String(repeating: "a", count: 1200), replacingPendingMessage: "tracks:task")
        await fulfillment(of: [entered], timeout: 2)
        try queue.enqueue("obsolete", replacingPendingMessage: "tracks:task")
        try queue.enqueue("latest", replacingPendingMessage: "tracks:task")
        gate.signal()
        try await queue.flush()
        XCTAssertEqual(recorder.packets.count, 3)
        let fragments = try recorder.packets.prefix(2).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(fragments.compactMap { $0["index"] as? Int }, [0, 1])
        XCTAssertEqual(fragments[0]["eventId"] as? String, fragments[1]["eventId"] as? String)
        XCTAssertEqual(recorder.packets.last, Data("latest".utf8))
    }

    func testDiscardOnlyRemovesMatchingPendingKey() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: recorder.append, onFailure: { _ in XCTFail() })
        defer { queue.close() }
        for _ in 0..<58 { try queue.enqueue("budget") }
        try await queue.flush()
        try queue.enqueue("discard", replacingPendingMessage: "tracks:old")
        try queue.enqueue("keep", replacingPendingMessage: "tracks:new")
        queue.discardPendingMessages(key: "tracks:old")
        try await queue.flush()
        XCTAssertEqual(recorder.packets.count, 59)
        XCTAssertEqual(recorder.packets.last, Data("keep".utf8))
    }

    func testCloseCancelsRateLimitedTrajectoryWithoutReportingFailure() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: recorder.append, onFailure: { _ in XCTFail() })
        for _ in 0..<58 { try queue.enqueue("budget") }
        try await queue.flush()
        let pending = try queue.enqueue("trajectory", replacingPendingMessage: "tracks:task")
        queue.close()
        do {
            try await pending.value
            XCTFail("Closing the room must cancel pending work")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.packets.count, 58)
    }

    func testQueueFlushReportsSendFailure() async throws {
        let expected = XmaxError(code: .rtcError, message: "send failed")
        let queue = RtcMessageQueue(send: { _ in throw expected }, onFailure: { _ in })
        try queue.enqueue("start")
        do {
            try await queue.flush()
            XCTFail("Expected send failure")
        } catch {
            XCTAssertEqual(error as? XmaxError, expected)
        }
        queue.close()
    }

    func testCancellingFlushDoesNotCancelQueuedMessages() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(send: recorder.append, onFailure: { _ in })
        for _ in 0..<8 { try queue.enqueue(String(repeating: "a", count: 800)) }
        let flush = Task { try await queue.flush() }
        flush.cancel()
        do {
            try await flush.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        try await queue.flush()
        XCTAssertEqual(recorder.packets.count, 8)
        queue.close()
    }
}

private final class PacketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    var packets: [Data] { lock.withLock { values } }

    func append(_ data: Data) {
        lock.withLock { values.append(data) }
    }
}

extension RtcMessageQueueTests {
    func testTRTCFragmentsUseServerProtocolAndPreserveUnicode() throws {
        let message = String(repeating: "换装🙂\\\"\n", count: 250)
        let packets = try RtcMessageCodec.encode(message, provider: .trtc)
        var result = ""
        var eventID: String?
        for (index, packet) in packets.enumerated() {
            XCTAssertLessThanOrEqual(packet.count, 1000)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: packet) as? [String: Any])
            XCTAssertEqual(value["event"] as? String, "__trtc_chunk__")
            XCTAssertEqual(value["index"] as? Int, index)
            XCTAssertEqual(value["count"] as? Int, packets.count)
            let current = try XCTUnwrap(value["eventId"] as? String)
            if let eventID { XCTAssertEqual(current, eventID) }
            eventID = current
            result += try XCTUnwrap(value["data"] as? String)
        }
        XCTAssertEqual(result, message)
    }

    func testTRTCQueueRespectsConservativeByteQuota() async throws {
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(provider: .trtc, send: recorder.append, onFailure: { _ in XCTFail() })
        defer { queue.close() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { try queue.enqueue(String(repeating: "a", count: 800)) }
        try await queue.flush()
        XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - start, 1_000_000_000)
        XCTAssertEqual(recorder.packets.count, 10)
    }
}

extension RtcMessageQueueTests {
    func testTRTCStartWaitsForExpectedRecipientWithoutRequiringVideoPublication() async throws {
        let readiness = TrtcSignalingReadiness()
        readiness.expectUser("bot")
        let waiting = expectation(description: "start reached recipient wait")
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(
            provider: .trtc,
            beforeSend: {
                if !readiness.isReady { waiting.fulfill() }
                try await readiness.waitUntilReady()
            },
            send: recorder.append,
            onFailure: { _ in XCTFail("Recipient startup delay must not fail signaling") }
        )
        defer { queue.close(); readiness.close() }
        let start = try queue.enqueue("start")
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertTrue(recorder.packets.isEmpty)
        readiness.setUserPresent("unrelated-user", present: true)
        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(recorder.packets.isEmpty)
        readiness.setUserPresent("bot", present: true)
        try await start.value
        XCTAssertEqual(recorder.packets, [Data("start".utf8)])
    }

    func testTRTCClosingRoomCancelsStartWaitingForRecipient() async throws {
        let readiness = TrtcSignalingReadiness()
        readiness.expectUser("bot")
        let waiting = expectation(description: "message is waiting")
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(
            provider: .trtc,
            beforeSend: {
                waiting.fulfill()
                try await readiness.waitUntilReady()
            },
            send: recorder.append,
            onFailure: { _ in XCTFail("Room teardown must not report a new send failure") }
        )
        let start = try queue.enqueue("start")
        await fulfillment(of: [waiting], timeout: 1)
        queue.close()
        readiness.close()
        readiness.setUserPresent("bot", present: true)
        do {
            try await start.value
            XCTFail("A start from a closed room must not be sent")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(recorder.packets.isEmpty)
    }

    func testTRTCRecipientWaitPreservesLatestUnsentSnapshot() async throws {
        let readiness = TrtcSignalingReadiness()
        readiness.expectUser("bot")
        let waiting = expectation(description: "snapshot is waiting")
        let recorder = PacketRecorder()
        let queue = RtcMessageQueue(
            provider: .trtc,
            beforeSend: {
                if !readiness.isReady { waiting.fulfill() }
                try await readiness.waitUntilReady()
            },
            send: recorder.append,
            onFailure: { _ in XCTFail() }
        )
        defer { queue.close(); readiness.close() }
        let first = try queue.enqueue("old", replacingPendingMessage: "snapshot")
        await fulfillment(of: [waiting], timeout: 1)
        let latest = try queue.enqueue("latest", replacingPendingMessage: "snapshot")
        readiness.setUserPresent("bot", present: true)
        try await first.value
        try await latest.value
        XCTAssertEqual(recorder.packets, [Data("latest".utf8)])
    }

    func testTRTCRecipientAlreadyPresentDoesNotMissReadiness() async throws {
        let readiness = TrtcSignalingReadiness()
        readiness.setUserPresent("bot", present: true)
        readiness.expectUser("bot")
        XCTAssertTrue(readiness.isReady)
        try await readiness.waitUntilReady()
        readiness.setUserPresent("bot", present: false)
        XCTAssertFalse(readiness.isReady)
        readiness.close()
        do {
            try await readiness.waitUntilReady()
            XCTFail("Closed room must fail immediately")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTRTCCancellingOneRecipientWaitDoesNotCancelOthers() async throws {
        let readiness = TrtcSignalingReadiness()
        readiness.expectUser("bot")
        let cancelled = Task { try await readiness.waitUntilReady() }
        let survivor = Task { try await readiness.waitUntilReady() }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Cancelled recipient wait must terminate")
        } catch { XCTAssertTrue(error is CancellationError) }
        readiness.setUserPresent("bot", present: true)
        try await survivor.value
        readiness.close()
    }
}

extension RtcMessageQueueTests {
    func testCancelledQueuedRetryReleasesCallerWithoutBypassingEarlierMessage() async throws {
        let recorder = PacketRecorder()
        let gate = AsyncThrowingStream<Void, any Error>.makeStream()
        let waiting = expectation(description: "initial message waiting")
        let queue = RtcMessageQueue(beforeSend: {
            waiting.fulfill()
            for try await _ in gate.stream {}
        }, send: recorder.append, onFailure: { _ in XCTFail("Cancellation must not fail the room") })
        waiting.assertForOverFulfill = false
        let first = try queue.enqueue("first", reportFailure: false)
        await fulfillment(of: [waiting], timeout: 1)
        let obsolete = try queue.enqueue("obsolete", reportFailure: false)
        obsolete.cancel()
        do { try await obsolete.value; XCTFail("Expected cancellation") } catch {}
        let next = try queue.enqueue("next", reportFailure: false)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(recorder.packets.isEmpty)
        gate.continuation.finish()
        try await first.value
        try await next.value
        XCTAssertEqual(recorder.packets, [Data("first".utf8), Data("next".utf8)])
        queue.close()
    }
}
