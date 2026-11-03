//
//  RtcEngineManagerTests.swift
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

final class RtcEngineManagerTests: XCTestCase {
    func testAcquireCreatesAndReleaseDestroysEngine() async throws {
        let lifecycle = RtcEngineLifecycleRecorder()
        let manager = makeManager(lifecycle: lifecycle)

        let lease = try await manager.acquire()

        XCTAssertEqual(lifecycle.createdAppIDs, ["test-app-id"])
        XCTAssertEqual(lifecycle.destroyCount, 0)

        await manager.release(lease)

        XCTAssertEqual(lifecycle.destroyCount, 1)
    }

    func testSecondAcquireWaitsUntilFirstLeaseIsReleased() async throws {
        let lifecycle = RtcEngineLifecycleRecorder()
        let manager = makeManager(lifecycle: lifecycle)
        let firstLease = try await manager.acquire()
        let secondTask = Task {
            try await manager.acquire()
        }

        await Task.yield()
        XCTAssertEqual(lifecycle.createdAppIDs.count, 1)

        await manager.release(firstLease)
        let secondLease = try await secondTask.value

        XCTAssertEqual(lifecycle.createdAppIDs.count, 2)
        XCTAssertEqual(lifecycle.destroyCount, 1)

        await manager.release(secondLease)
        XCTAssertEqual(lifecycle.destroyCount, 2)
    }

    func testCancelledWaiterDoesNotAcquireEngine() async throws {
        let lifecycle = RtcEngineLifecycleRecorder()
        let manager = makeManager(lifecycle: lifecycle)
        let firstLease = try await manager.acquire()
        let waitingTask = Task {
            try await manager.acquire()
        }

        await Task.yield()
        waitingTask.cancel()

        do {
            _ = try await waitingTask.value
            XCTFail("Expected the waiting acquisition to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await manager.release(firstLease)

        XCTAssertEqual(lifecycle.createdAppIDs.count, 1)
        XCTAssertEqual(lifecycle.destroyCount, 1)
    }

    func testReleaseIgnoresLeaseOwnedByAnotherManager() async throws {
        let firstLifecycle = RtcEngineLifecycleRecorder()
        let secondLifecycle = RtcEngineLifecycleRecorder()
        let firstManager = makeManager(lifecycle: firstLifecycle)
        let secondManager = makeManager(lifecycle: secondLifecycle)
        let firstLease = try await firstManager.acquire()
        let secondLease = try await secondManager.acquire()

        await firstManager.release(secondLease)
        XCTAssertEqual(firstLifecycle.destroyCount, 0)

        await firstManager.release(firstLease)
        await secondManager.release(secondLease)
        XCTAssertEqual(firstLifecycle.destroyCount, 1)
        XCTAssertEqual(secondLifecycle.destroyCount, 1)
    }

    func testAcquireRejectsEmptyAppID() async {
        let lifecycle = RtcEngineLifecycleRecorder()
        let manager = RtcEngineManager(
            appID: " \n ",
            makeEngine: lifecycle.create,
            destroyEngine: lifecycle.destroy
        )

        do {
            _ = try await manager.acquire()
            XCTFail("Expected RTC App ID validation to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .rtcError,
                    message: "RTC App ID cannot be empty"
                )
            )
        }

        XCTAssertTrue(lifecycle.createdAppIDs.isEmpty)
        XCTAssertEqual(lifecycle.destroyCount, 0)
    }

    func testAcquireMapsEngineCreationFailure() async {
        let lifecycle = RtcEngineLifecycleRecorder(shouldFailCreation: true)
        let manager = makeManager(lifecycle: lifecycle)

        do {
            _ = try await manager.acquire()
            XCTFail("Expected RTC Engine creation to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .rtcError,
                    message: "Failed to create RTC Engine"
                )
            )
        }

        XCTAssertEqual(lifecycle.createdAppIDs, ["test-app-id"])
        XCTAssertEqual(lifecycle.destroyCount, 0)
    }

    private func makeManager(
        lifecycle: RtcEngineLifecycleRecorder
    ) -> RtcEngineManager {
        RtcEngineManager(
            appID: " test-app-id ",
            makeEngine: lifecycle.create,
            destroyEngine: lifecycle.destroy
        )
    }
}

final class RtcEngineLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let shouldFailCreation: Bool
    private var appIDs: [String] = []
    private var destructions = 0

    init(shouldFailCreation: Bool = false) {
        self.shouldFailCreation = shouldFailCreation
    }

    var createdAppIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return appIDs
    }

    var destroyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return destructions
    }

    func create(appID: String) -> (any RtcPlatform)? {
        lock.lock()
        appIDs.append(appID)
        lock.unlock()

        return shouldFailCreation ? nil : RtcPlatformStub()
    }

    func destroy() {
        lock.lock()
        destructions += 1
        lock.unlock()
    }
}
