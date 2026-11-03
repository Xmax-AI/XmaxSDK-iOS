import Foundation
import XCTest
import XmaxSDK

@MainActor
final class FeedCreditBalanceTests: XCTestCase {
    func testNoRequestForEmptyKeyOrHiddenHomepage() async {
        let poller = FeedCreditBalancePoller(makeQuery: { _, _ in
            XCTFail("Must not query")
            return { 0 }
        })
        poller.update(apiKey: " ", environment: .china, isActive: true)
        poller.update(apiKey: "key", environment: .china, isActive: false)
        await Task.yield()
        XCTAssertEqual(poller.state, FeedCreditBalanceState())
    }

    func testRefreshFailureKeepsLastBalanceAndWaitsFiveSeconds() async {
        let values = CreditSequence()
        let failed = expectation(description: "refresh failed with retained balance")
        let poller = FeedCreditBalancePoller(
            makeQuery: { _, _ in { try await values.next() } },
            wait: { delay in
                if delay == 5_000_000_000 { try await values.waitForCycle(delay) }
            }
        )
        poller.onChange = { state in
            if state.refreshFailed { failed.fulfill() }
        }
        poller.update(apiKey: "key", environment: .china, isActive: true)
        await fulfillment(of: [failed], timeout: 2)
        poller.update(apiKey: "key", environment: .china, isActive: false)
        XCTAssertEqual(poller.state.balance, 1250.75)
        XCTAssertTrue(poller.state.refreshFailed)
        let intervals = await values.intervals
        XCTAssertEqual(intervals.first, 5_000_000_000)
    }

    func testAccountChangeRejectsLateResponseFromCancelledRequest() async {
        let old = DelayedCreditResult()
        let entered = expectation(description: "old request entered")
        let fresh = expectation(description: "new account response")
        let poller = FeedCreditBalancePoller(
            makeQuery: { key, _ in
                if key == "old" { return { await old.fetch(entered: entered) } }
                return { 42.5 }
            },
            wait: { delay in if delay == 5_000_000_000 { try await Task.sleep(nanoseconds: delay) }
            }
        )
        poller.update(apiKey: "old", environment: .china, isActive: true)
        await fulfillment(of: [entered], timeout: 2)
        poller.onChange = { if $0.balance == 42.5 { fresh.fulfill() } }
        poller.update(apiKey: "new", environment: .global, isActive: true)
        XCTAssertNil(poller.state.balance)
        await fulfillment(of: [fresh], timeout: 2)
        await old.complete(999)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(poller.state.balance, 42.5)
        poller.update(apiKey: "new", environment: .global, isActive: false)
    }

    func testEnvironmentChangeClearsCachedBalanceAndPausePreservesIt() async {
        let loaded = expectation(description: "balance loaded")
        let poller = FeedCreditBalancePoller(
            makeQuery: { _, _ in { 1 } },
            wait: { delay in if delay == 5_000_000_000 { try await Task.sleep(nanoseconds: delay) }
            }
        )
        poller.onChange = { if $0.balance == 1 { loaded.fulfill() } }
        poller.update(apiKey: "key", environment: .china, isActive: true)
        await fulfillment(of: [loaded], timeout: 2)
        poller.update(apiKey: "key", environment: .china, isActive: false)
        XCTAssertEqual(poller.state.balance, 1)
        poller.update(apiKey: "key", environment: .global, isActive: false)
        XCTAssertNil(poller.state.balance)
    }

    func testFormattingMatchesAndroidAndPreservesZero() {
        XCTAssertEqual(formatFeedCreditBalance(nil), "—")
        XCTAssertEqual(formatFeedCreditBalance(0), "0")
        XCTAssertEqual(formatFeedCreditBalance(1250.75), "1,250.75")
        XCTAssertEqual(formatFeedCreditBalance(0.1234567), "0.123457")
    }
}

private actor CreditSequence {
    private var calls = 0
    var intervals: [UInt64] = []
    func waitForCycle(_ value: UInt64) async throws {
        intervals.append(value)
        if intervals.count > 1 { try await Task.sleep(nanoseconds: value) }
    }
    func next() throws -> Double {
        calls += 1
        if calls == 1 { return 1250.75 }
        throw URLError(.notConnectedToInternet)
    }
}

private actor DelayedCreditResult {
    private var continuation: CheckedContinuation<Double, Never>?
    func fetch(entered: XCTestExpectation) async -> Double {
        await withCheckedContinuation { value in
            continuation = value
            entered.fulfill()
        }
    }
    func complete(_ value: Double) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
