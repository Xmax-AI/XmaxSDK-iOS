//
//  XmaxRealtimeLifecycleManagerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import XCTest
@testable import XmaxSDK

@MainActor
final class XmaxRealtimeLifecycleManagerTests: XCTestCase {
    func testReplacementWaitsForStartupAndRetainsTheEstablishedConnection() async throws {
        let gate = LifecycleFailureGate()
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let lifecycle = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            cleanup: { scope, _ in
                await probe.recordCleanup(scope)
                return .init(sessionID: "session", hasLocalMedia: true)
            }
        )
        var states: [RealtimeState] = []
        await lifecycle.setStateListener { states.append($0) }
        let first = Task {
            try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                try await lifecycle.commit(RealtimeState(connectionState: .connected, sessionID: "session"), token: token)
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    events.append("cancelled")
                }
                try token.ensureCurrent()
                XCTFail("Replaced startup must not commit a late result")
            }
        }
        await waitUntil { await gate.isWaiting }
        let replacement = Task {
            try await lifecycle.run(kind: .generation) { token in
                events.append("replacement")
                try await lifecycle.complete(RealtimeState(connectionState: .generating, sessionID: "session", taskID: "new"), token: token)
            }
        }
        await waitUntil { events.values.contains("cancelled") }
        XCTAssertFalse(events.values.contains("replacement"))
        await gate.release()
        try await replacement.value
        do { try await first.value; XCTFail("Expected replaced startup cancellation") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        let scopes = await probe.cleanupScopes
        let state = await lifecycle.currentState
        XCTAssertEqual(scopes, [.generation])
        XCTAssertEqual(state.taskID, "new")
        XCTAssertEqual(state.connectionState, .generating)
        XCTAssertFalse(states.contains { $0.connectionState == .disconnecting })
        XCTAssertFalse(states.contains { $0.reason != nil })
    }

    func testLatestGenerationSkipsIntermediateRequestWhileRollbackIsPending() async throws {
        let cleanupGate = LifecycleFailureGate()
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let lifecycle = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            cleanup: { _, _ in
                await cleanupGate.wait()
                return .init(sessionID: "session", hasLocalMedia: true)
            }
        )
        let first = Task {
            try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                try await lifecycle.commit(RealtimeState(connectionState: .connected, sessionID: "session"), token: token)
                events.append("first")
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        await waitUntil { events.values.contains("first") }
        let intermediate = Task {
            try await lifecycle.run(kind: .generation) { _ in events.append("intermediate") }
        }
        await waitUntil { await cleanupGate.isWaiting }
        let release = Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            await cleanupGate.release()
        }
        try await lifecycle.run(kind: .generation) { token in
            events.append("latest")
            try token.ensureCurrent()
        }
        try await release.value
        do { try await first.value; XCTFail("Expected first cancellation") } catch {}
        do { try await intermediate.value; XCTFail("Expected intermediate cancellation") } catch {}
        XCTAssertEqual(events.values, ["first", "latest"])
    }

    func testReplacementDuringConnectionSetupReleasesTheIncompleteConnection() async throws {
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let lifecycle = makeCoordinator(probe: probe)
        let first = Task {
            try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                try await lifecycle.commit(RealtimeState(connectionState: .connecting), token: token)
                events.append("connecting")
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        await waitUntil { events.values.contains("connecting") }
        try await lifecycle.run(kind: .generation) { token in
            try await lifecycle.complete(RealtimeState(connectionState: .generating, taskID: "new"), token: token)
        }
        do { try await first.value; XCTFail("Expected connection setup cancellation") } catch {}
        let scopes = await probe.cleanupScopes
        XCTAssertEqual(scopes, [.connection])
    }

    func testOverlappingConditionUpdatesPreserveTheRunningGeneration() async throws {
        let gate = LifecycleFailureGate()
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let lifecycle = makeCoordinator(probe: probe)
        try await lifecycle.run(kind: .generation) { token in
            try await lifecycle.complete(RealtimeState(connectionState: .generating, taskID: "original"), token: token)
        }
        let first = Task {
            try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    events.append("cancelled")
                }
                try token.ensureCurrent()
                events.append("stale")
            }
        }
        await waitUntil { await gate.isWaiting }
        let replacement = Task {
            try await lifecycle.run(kind: .generation) { _ in events.append("latest") }
        }
        await waitUntil { events.values.contains("cancelled") }
        await gate.release()
        try await replacement.value
        do { try await first.value; XCTFail("Expected update cancellation") } catch {}
        let state = await lifecycle.currentState
        let scopes = await probe.cleanupScopes
        XCTAssertEqual(state.taskID, "original")
        XCTAssertEqual(state.connectionState, .generating)
        XCTAssertTrue(scopes.isEmpty)
        XCTAssertEqual(events.values, ["cancelled", "latest"])
    }

    func testDisconnectAndCloseCancelTheLatestWaitingRequestWithoutRestarting() async throws {
        for target in [XmaxRealtimeLifecycleManager.TerminationScope.connection, .all] {
            let gate = LifecycleFailureGate()
            let events = XmaxRealtimeLifecycleManagerEventRecorder()
            let probe = XmaxRealtimeLifecycleManagerProbe()
            let lifecycle = makeCoordinator(probe: probe)
            let first = Task {
                try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                    try await lifecycle.commit(RealtimeState(connectionState: .connected), token: token)
                    await withTaskCancellationHandler {
                        await gate.wait()
                    } onCancel: {
                        events.append("cancelled")
                    }
                    try token.ensureCurrent()
                }
            }
            await waitUntil { await gate.isWaiting }
            let replacement = Task {
                try await lifecycle.run(kind: .generation) { _ in events.append("unexpected restart") }
            }
            await waitUntil { events.values.contains("cancelled") }
            let termination = Task { await lifecycle.terminate(target) }
            await waitUntil { await lifecycle.currentState.connectionState == .disconnecting }
            await gate.release()
            await termination.value
            do { try await first.value; XCTFail("Expected startup cancellation") } catch {}
            do { try await replacement.value; XCTFail("Expected pending request cancellation") } catch {}
            let scopes = await probe.cleanupScopes
            XCTAssertEqual(scopes, [target])
            XCTAssertFalse(events.values.contains("unexpected restart"))
        }
    }

    func testConnectionFailureDuringGenerationRollbackCancelsReplacement() async throws {
        let cleanupGate = LifecycleFailureGate()
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let lifecycle = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            cleanup: { scope, _ in
                await probe.recordCleanup(scope)
                if scope == .generation {
                    await cleanupGate.wait()
                }
                return .init(sessionID: "session", hasLocalMedia: true)
            }
        )
        let first = Task {
            try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                try await lifecycle.commit(RealtimeState(connectionState: .connected), token: token)
                events.append("first")
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        await waitUntil { events.values.contains("first") }
        let replacement = Task {
            try await lifecycle.run(kind: .generation) { _ in events.append("unexpected restart") }
        }
        await waitUntil { await cleanupGate.isWaiting }
        let error = XmaxError(code: .rtcError, message: "Connection lost")
        let failure = Task { await lifecycle.terminate(with: error, target: .connection) }
        await waitUntil { await lifecycle.currentState.connectionState == .disconnecting }
        await cleanupGate.release()
        await failure.value
        do { try await first.value; XCTFail("Expected startup failure") } catch {}
        do { try await replacement.value; XCTFail("Expected pending request cancellation") } catch {}
        let scopes = await probe.cleanupScopes
        let state = await lifecycle.currentState
        XCTAssertEqual(scopes, [.generation, .connection])
        XCTAssertEqual(state.connectionState, .ready)
        XCTAssertEqual(state.reason, .failure(error))
        XCTAssertFalse(events.values.contains("unexpected restart"))
    }

    func testCompletionListenerCanSubmitAnotherGenerationRequest() async throws {
        let lifecycle = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
        var followup: Task<Void, any Error>?
        await lifecycle.setStateListener { state in
            guard state.taskID == "first" else { return }
            followup = Task {
                try await lifecycle.run(kind: .generation) { token in
                    try await lifecycle.complete(RealtimeState(connectionState: .generating, taskID: "second"), token: token)
                }
            }
        }
        try await lifecycle.run(kind: .generation) { token in
            try await lifecycle.complete(RealtimeState(connectionState: .generating, taskID: "first"), token: token)
        }
        try await XCTUnwrap(followup).value
        let state = await lifecycle.currentState
        XCTAssertEqual(state.taskID, "second")
    }

    func testRejectedMediaOperationPreservesTheExistingPreparation() async throws {
        let lifecycle = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
        try await lifecycle.run(kind: .media) { token in
            try await lifecycle.commit(RealtimeState(connectionState: .preparing), token: token)
        }
        do {
            try await lifecycle.run(kind: .media) { _ in
                throw XmaxError(code: .invalidConfiguration, message: "Existing stream is preparing")
            }
            XCTFail("Expected rejected operation")
        } catch {}
        let state = await lifecycle.currentState
        XCTAssertEqual(state, RealtimeState(connectionState: .preparing))
    }

    func testCompletionListenerCanImmediatelySubmitTheNextOperation() async throws {
        for state in [RealtimeConnectionState.ready, .connected, .generating] {
            let lifecycle = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
            var followup: Task<Void, any Error>?
            await lifecycle.setStateListener { snapshot in
                guard snapshot.connectionState == state else { return }
                followup = Task {
                    try await lifecycle.run(kind: .configuration) { token in
                        try token.ensureCurrent()
                    }
                }
            }
            try await lifecycle.run(kind: .generation) { token in
                try await lifecycle.complete(RealtimeState(connectionState: state), token: token)
            }
            try await XCTUnwrap(followup).value
        }
    }

    func testCompletionWaitsForTheOperationBodyToFinish() async throws {
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let lifecycle = makeCoordinator(
            probe: XmaxRealtimeLifecycleManagerProbe(),
            onStateChanged: { state in
                if state.connectionState == .generating {
                    events.append("internal")
                }
            }
        )
        await lifecycle.setStateListener { state in
            if state.connectionState == .generating {
                events.append("listener")
            }
        }
        let gate = LifecycleFailureGate()
        let operation = Task {
            try await lifecycle.run(kind: .generation) { token in
                try await lifecycle.complete(RealtimeState(connectionState: .generating), token: token)
                await gate.wait()
            }
        }
        await waitUntil { await gate.isWaiting }
        let pending = await lifecycle.currentState
        XCTAssertEqual(pending.connectionState, .idle)
        XCTAssertTrue(events.values.isEmpty)
        await gate.release()
        try await operation.value
        let completed = await lifecycle.currentState
        XCTAssertEqual(completed.connectionState, .generating)
        XCTAssertEqual(events.values, ["internal", "listener"])
    }

    func testCancellationDiscardsStagedCompletionWithoutInvokingTheStateHook() async {
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let lifecycle = makeCoordinator(
            probe: XmaxRealtimeLifecycleManagerProbe(),
            onStateChanged: { state in
                if state.connectionState == .generating {
                    events.append("generating")
                }
            }
        )
        let gate = LifecycleFailureGate()
        let operation = Task {
            try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                try await lifecycle.complete(
                    RealtimeState(connectionState: .generating, sessionID: "session"),
                    token: token
                )
                await gate.wait()
            }
        }
        await waitUntil { await gate.isWaiting }
        operation.cancel()
        await gate.release()
        do {
            try await operation.value
            XCTFail("Expected cancellation before committing completion")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertTrue(events.values.isEmpty)
        let state = await lifecycle.currentState
        XCTAssertEqual(state.connectionState, .idle)
    }

    func testStateHookDoesNotPublishCompletionSupersededByTermination() async throws {
        let gate = LifecycleFailureGate()
        let lifecycle = makeCoordinator(
            probe: XmaxRealtimeLifecycleManagerProbe(),
            onStateChanged: { state in
                if state.connectionState == .generating {
                    await gate.wait()
                }
            }
        )
        var states: [RealtimeConnectionState] = []
        await lifecycle.setStateListener { states.append($0.connectionState) }
        let operation = Task {
            try await lifecycle.run(kind: .generation) { token in
                try await lifecycle.complete(
                    RealtimeState(connectionState: .generating, sessionID: "session"),
                    token: token
                )
            }
        }
        await waitUntil { await gate.isWaiting }
        let committed = await lifecycle.currentState
        XCTAssertEqual(committed.connectionState, .generating)
        await lifecycle.terminate(.all)
        await gate.release()
        try await operation.value
        XCTAssertFalse(states.contains(.generating))
        XCTAssertEqual(states.last, .idle)
    }

    func testFailureDiscardsAStagedCompletion() async {
        let lifecycle = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
        var states: [RealtimeConnectionState] = []
        await lifecycle.setStateListener { states.append($0.connectionState) }
        do {
            try await lifecycle.run(kind: .generation, failureScope: .connection) { token in
                try await lifecycle.complete(RealtimeState(connectionState: .generating), token: token)
                throw XmaxError(code: .rtcError, message: "Startup failed after staging completion")
            }
            XCTFail("Expected failure")
        } catch {}
        XCTAssertFalse(states.contains(.generating))
        let final = await lifecycle.currentState
        XCTAssertEqual(final.connectionState, .idle)
    }

    func testForegroundWaitsForAdaptiveCommitWithoutConflict() async throws {
        let gate = LifecycleFailureGate()
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let coordinator = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
        try await coordinator.run(kind: .generation) { token in
            try await coordinator.commit(RealtimeState(connectionState: .generating, taskID: "task"), token: token)
        }
        let background = Task {
            try await coordinator.runAdaptiveConfiguration { token in
                events.append("sent")
                await gate.wait()
                try token.ensureCurrent()
                events.append("committed")
            }
        }
        await waitUntil { await gate.isWaiting }
        let foreground = Task {
            try await coordinator.run(kind: .configuration) { token in
                try token.ensureCurrent()
                events.append("foreground")
            }
        }
        let skipped = try await coordinator.runAdaptiveConfiguration { _ in XCTFail("Busy background must be skipped") }
        XCTAssertFalse(skipped)
        await gate.release()
        _ = try await background.value
        try await foreground.value
        XCTAssertEqual(events.values, ["sent", "committed", "foreground"])
        let state = await coordinator.currentState
        XCTAssertEqual(state.connectionState, .generating)
    }

    func testDisconnectInvalidatesAdaptiveTaskBeforeNextGeneration() async throws {
        let gate = LifecycleFailureGate()
        let coordinator = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
        try await coordinator.run(kind: .generation) { token in
            try await coordinator.commit(RealtimeState(connectionState: .generating), token: token)
        }
        let background = Task {
            try await coordinator.runAdaptiveConfiguration { token in
                await gate.wait()
                try token.ensureCurrent()
                XCTFail("An ended connection must not commit quality")
            }
        }
        await waitUntil { await gate.isWaiting }
        let disconnect = Task { await coordinator.disconnect() }
        await waitUntil { await coordinator.currentState.connectionState == .disconnecting }
        await gate.release()
        do { _ = try await background.value; XCTFail("Expected cancellation") } catch {}
        await disconnect.value
        try await coordinator.run(kind: .generation) { token in
            try await coordinator.commit(RealtimeState(connectionState: .generating, taskID: "new"), token: token)
        }
        let accepted = try await coordinator.runAdaptiveConfiguration { token in try token.ensureCurrent() }
        XCTAssertTrue(accepted)
    }

    func testBeginDisconnectAllowsLocalAdjustmentWhileCleanupIsWaiting() async throws {
        let gate = LifecycleFailureGate()
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let coordinator = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            cleanup: { _, _ in
                await gate.wait()
                return .init(hasLocalMedia: true)
            }
        )
        try await coordinator.run(kind: .connection) { token in
            try await coordinator.commit(RealtimeState(connectionState: .connected), token: token)
        }

        let operation = Task {
            let cleanup = await coordinator.beginDisconnect(reason: .orientationChanged)
            events.append("local-adjustment")
            await cleanup?.value
        }
        await waitUntil { await gate.isWaiting }
        await waitUntil { events.values.contains("local-adjustment") }
        let pendingState = await coordinator.currentState
        XCTAssertEqual(pendingState.connectionState, .disconnecting)

        await gate.release()
        await operation.value
        let finalState = await coordinator.currentState
        XCTAssertEqual(finalState.connectionState, .ready)
        XCTAssertEqual(finalState.reason, .orientationChanged)
    }

    func testOrientationChangeDisconnectsActiveConnectionAndPreservesLocalMedia() async throws {
        for initialState in [
            RealtimeConnectionState.connecting, .connected, .generating
        ] {
            let probe = XmaxRealtimeLifecycleManagerProbe()
            let coordinator = XmaxRealtimeLifecycleManager(
                errorManager: XmaxRealtimeErrorManager(),
                cleanup: { scope, _ in
                    await probe.recordCleanup(scope)
                    return .init(hasLocalMedia: true)
                }
            )
            try await coordinator.run(kind: .connection) { token in
                try await coordinator.commit(
                    RealtimeState(connectionState: initialState), token: token
                )
            }

            await coordinator.disconnect(reason: .orientationChanged)

            let state = await coordinator.currentState
            let scopes = await probe.cleanupScopes
            XCTAssertEqual(state.connectionState, .ready)
            XCTAssertEqual(state.reason, .orientationChanged)
            XCTAssertEqual(scopes, [.connection])
        }
    }

    func testOrientationChangeDoesNotInterruptUnconnectedLocalPreview() async throws {
        for initialState in [
            RealtimeConnectionState.idle, .preparing, .ready
        ] {
            let probe = XmaxRealtimeLifecycleManagerProbe()
            let coordinator = makeCoordinator(probe: probe)
            try await coordinator.run(kind: .media) { token in
                try await coordinator.commit(
                    RealtimeState(connectionState: initialState), token: token
                )
            }

            await coordinator.disconnect(reason: .orientationChanged)

            let state = await coordinator.currentState
            let scopes = await probe.cleanupScopes
            XCTAssertEqual(state.connectionState, initialState)
            XCTAssertNil(state.reason)
            XCTAssertTrue(scopes.isEmpty)
        }
    }

    func testPreviewReadyOnlyAdvancesCurrentPreparation() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        try await coordinator.run(kind: .media) { token in
            try await coordinator.commit(RealtimeState(connectionState: .preparing), token: token)
        }

        await coordinator.localPreviewDidBecomeReady(isCurrent: { false })
        let staleState = await coordinator.currentState
        XCTAssertEqual(staleState.connectionState, .preparing)

        await coordinator.localPreviewDidBecomeReady(isCurrent: { true })
        let readyState = await coordinator.currentState
        XCTAssertEqual(readyState.connectionState, .ready)

        try await coordinator.run(kind: .connection) { token in
            try await coordinator.commit(RealtimeState(connectionState: .connecting), token: token)
        }
        await coordinator.localPreviewDidBecomeReady(isCurrent: { true })
        let connectingState = await coordinator.currentState
        XCTAssertEqual(connectingState.connectionState, .connecting)

        await coordinator.terminate(.all)
        await coordinator.localPreviewDidBecomeReady(isCurrent: { false })
        let closedState = await coordinator.currentState
        XCTAssertEqual(closedState.connectionState, .idle)
    }

    func testNewGenerationWaitsForCancelledDisconnectTaskToFinishCleanup() async throws {
        let gate = LifecycleFailureGate()
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let coordinator = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            cleanup: { _, _ in
                await gate.wait()
                events.append("cleanup-finished")
                return .init(hasLocalMedia: true)
            }
        )
        try await coordinator.run(kind: .generation) { token in
            try await coordinator.commit(RealtimeState(connectionState: .generating), token: token)
        }

        let disconnecting = Task { await coordinator.disconnect() }
        await waitUntil { await gate.isWaiting }
        disconnecting.cancel()
        let nextGeneration = Task {
            await disconnecting.value
            try await coordinator.run(kind: .generation) { token in
                events.append("next-generation-started")
                try await coordinator.commit(RealtimeState(connectionState: .generating), token: token)
            }
        }

        let closingState = await coordinator.currentState
        XCTAssertEqual(closingState.connectionState, .disconnecting)
        XCTAssertTrue(events.values.isEmpty)
        await gate.release()
        try await nextGeneration.value

        let finalState = await coordinator.currentState
        XCTAssertEqual(finalState, RealtimeState(connectionState: .generating))
        XCTAssertEqual(events.values, ["cleanup-finished", "next-generation-started"])
    }

    func testMediaPreparationFailureReturnsToIdleWithoutFailureReason() async {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        var states: [RealtimeState] = []
        await coordinator.setStateListener { states.append($0) }

        do {
            try await coordinator.run(kind: .media) { token in
                try await coordinator.commit(RealtimeState(connectionState: .preparing), token: token)
                throw XmaxError(code: .invalidConfiguration, message: "Invalid media")
            }
            XCTFail("Expected creation failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }

        XCTAssertEqual(states.map(\.connectionState), [.idle, .preparing, .idle])
        XCTAssertTrue(states.allSatisfy { $0.reason == nil })
        let cleanup = await probe.cleanupScopes
        XCTAssertTrue(cleanup.isEmpty)
    }

    func testMediaPreparationCancellationAndCloseReturnToIdle() async {
        for closes in [false, true] {
            let probe = XmaxRealtimeLifecycleManagerProbe()
            let coordinator = makeCoordinator(probe: probe)
            let preparing = Task {
                try await coordinator.run(kind: .media) { token in
                    try await coordinator.commit(RealtimeState(connectionState: .preparing), token: token)
                    await probe.markOperationStarted()
                    try await Task.sleep(nanoseconds: 30000000000)
                    try await coordinator.commit(RealtimeState(connectionState: .ready), token: token)
                }
            }
            await waitUntil { await probe.operationStarted }

            if closes {
                await coordinator.terminate(.all)
            } else {
                preparing.cancel()
            }
            do {
                try await preparing.value
                XCTFail("Expected preparation cancellation")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
            }

            let state = await coordinator.currentState
            let cleanup = await probe.cleanupScopes
            XCTAssertEqual(state.connectionState, .idle)
            XCTAssertEqual(state.reason, closes ? .normal : nil)
            XCTAssertEqual(cleanup, closes ? [.all] : [])
        }
    }

    func testConnectionCleanupKeepsQueuedMediaFailureValidButCloseInvalidatesIt() async {
        for target: XmaxRealtimeLifecycleManager.TerminationScope in [.connection, .all] {
            let handler = XmaxRealtimeErrorManager()
            let gate = LifecycleFailureGate()
            let delivered = expectation(description: "Queued failure processed")
            let result = XmaxRealtimeLifecycleManagerEventRecorder()
            handler.setFailureHandler { _, _, isCurrent in
                await gate.wait()
                result.append(isCurrent() ? "valid" : "stale")
                delivered.fulfill()
            }
            handler.forward(XmaxError(code: .mediaError, message: "Capture stopped"), target: .all)
            await waitUntil { await gate.isWaiting }
            handler.invalidatePendingFailures(target: target)
            await gate.release()
            await fulfillment(of: [delivered], timeout: 2)
            XCTAssertEqual(result.values, [target == .all ? "stale" : "valid"])
        }
    }


    func testPreflightFailureDoesNotChangeReadyStateOrCleanUp() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        try await coordinator.run(kind: .media) { token in
            try await coordinator.commit(RealtimeState(connectionState: .ready), token: token)
        }
        do {
            try await coordinator.run(kind: .generation) { _ in
                throw XmaxError(code: .invalidConfiguration, message: "Missing context")
            }
            XCTFail("Expected preflight failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        let state = await coordinator.currentState
        let scopes = await probe.cleanupScopes
        XCTAssertEqual(state, RealtimeState(connectionState: .ready))
        XCTAssertTrue(scopes.isEmpty)
    }

    func testStartupFailureClosesConnectionAndPreservesReadyMedia() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            cleanup: { scope, _ in
                await probe.recordCleanup(scope)
                return .init(sessionID: "session", hasLocalMedia: true)
            }
        )
        let failure = XmaxError(code: .timeout, message: "First frame timed out")
        do {
            try await coordinator.run(kind: .generation) { token in
                token.setFailureScope(.connection)
                try await coordinator.commit(
                    RealtimeState(connectionState: .connected, sessionID: "session"), token: token
                )
                throw failure
            }
        } catch {
            XCTAssertEqual(error as? XmaxError, failure)
        }
        let state = await coordinator.currentState
        let scopes = await probe.cleanupScopes
        XCTAssertEqual(state.connectionState, .ready)
        XCTAssertEqual(state.reason, .failure(failure))
        XCTAssertEqual(scopes, [.connection])
    }

    func testMediaTerminationWithoutConnectionReportsIdleFailure() async {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let failure = XmaxError(code: .mediaError, message: "Decoder stopped")
        await coordinator.terminate(with: failure, target: .all)
        let state = await coordinator.currentState
        let scopes = await probe.cleanupScopes
        XCTAssertEqual(state.connectionState, .idle)
        XCTAssertEqual(state.reason, .failure(failure))
        XCTAssertEqual(scopes, [.all])
    }

    func testConfigurationFailurePreservesGeneratingAfterRtcError() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let original = RealtimeState(connectionState: .generating, sessionID: "session", taskID: "task")
        try await coordinator.run(kind: .generation) { token in
            try await coordinator.commit(original, token: token)
        }
        do {
            try await coordinator.run(kind: .generation, failureScope: .connection) { _ in
                throw XmaxError(code: .rtcError, message: "Condition send failed")
            }
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .rtcError)
        }
        let state = await coordinator.currentState
        let scopes = await probe.cleanupScopes
        XCTAssertEqual(state, original)
        XCTAssertTrue(scopes.isEmpty)
    }

    func testStaleBackgroundFailureDoesNotCloseCurrentConnection() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let original = RealtimeState(connectionState: .connected, sessionID: "new")
        try await coordinator.run(kind: .connection) { token in
            try await coordinator.commit(original, token: token)
        }
        await coordinator.terminate(
            with: XmaxError(code: .mediaError, message: "Old source failed"),
            target: .all,
            isCurrent: { false }
        )
        let state = await coordinator.currentState
        let scopes = await probe.cleanupScopes
        XCTAssertEqual(state, original)
        XCTAssertTrue(scopes.isEmpty)
    }

    func testOrientationDisconnectReturnsReadyAndNextConnectClearsReason() async throws {
        let coordinator = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(), cleanup: { _, _ in .init(hasLocalMedia: true) }
        )
        try await coordinator.run(kind: .connection) { token in
            try await coordinator.commit(RealtimeState(connectionState: .connected), token: token)
        }
        await coordinator.disconnect(reason: .orientationChanged)
        let ready = await coordinator.currentState
        XCTAssertEqual(ready.connectionState, .ready)
        XCTAssertEqual(ready.reason, .orientationChanged)
        try await coordinator.run(kind: .connection) { token in
            try await coordinator.commit(RealtimeState(connectionState: .connecting), token: token)
        }
        let connecting = await coordinator.currentState
        XCTAssertNil(connecting.reason)
    }

    func testNormalTerminationReportsReasonAndReconnectClearsIt() async throws {
        for scope: XmaxRealtimeLifecycleManager.TerminationScope in [.connection, .all] {
            let coordinator = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
            var states: [RealtimeState] = []
            await coordinator.setStateListener { states.append($0) }
            try await coordinator.run(kind: .connection, failureScope: .connection) { token in
                try await coordinator.commit(
                    RealtimeState(connectionState: .connected, sessionID: "session"),
                    token: token
                )
            }

            if scope == .connection {
                await coordinator.disconnect()
            } else {
                await coordinator.terminate(.all)
            }

            XCTAssertEqual(states.map(\.connectionState), [.idle, .connected, .disconnecting, .idle])
            XCTAssertEqual(states.map(\.reason), [nil, nil, nil, .normal])
            XCTAssertEqual(states.last?.reason, .normal)

            try await coordinator.run(kind: .connection, failureScope: .connection) { token in
                try await coordinator.commit(RealtimeState(connectionState: .connecting), token: token)
            }
            let state = await coordinator.currentState
            XCTAssertNil(state.reason)
        }
    }

    func testConnectionFailureDoesNotReportNormalDisconnection() async {
        let coordinator = makeCoordinator(probe: XmaxRealtimeLifecycleManagerProbe())
        var states: [RealtimeState] = []
        await coordinator.setStateListener { states.append($0) }
        do {
            try await coordinator.run(kind: .connection, failureScope: .connection) { _ in
                throw XmaxError(code: .rtcError, message: "Connection failed")
            }
            XCTFail("Expected connection failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .rtcError)
        }
        XCTAssertEqual(states.map(\.connectionState), [.idle, .disconnecting, .idle])
        XCTAssertEqual(states.last?.reason, .failure(XmaxError(code: .rtcError, message: "Connection failed")))
    }

    func testCancellingConfigurationDoesNotStopGeneration() async throws {
        for kind: XmaxRealtimeLifecycleManager.OperationKind in [.configuration, .generation] {
            try await assertCancellingUpdatePreservesGeneration(kind: kind)
        }
    }

    private func assertCancellingUpdatePreservesGeneration(
        kind: XmaxRealtimeLifecycleManager.OperationKind
    ) async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let state = RealtimeState(connectionState: .generating, sessionID: "session", taskID: "task")
        try await coordinator.run(kind: .generation, failureScope: .connection) { token in
            try await coordinator.commit(state, token: token)
        }
        let changing = Task {
            try await coordinator.run(kind: kind, failureScope: .connection) { _ in
                await probe.markOperationStarted()
                try await Task.sleep(nanoseconds: 30000000000)
            }
        }
        await waitUntil { await probe.operationStarted }
        changing.cancel()
        do {
            try await changing.value
            XCTFail("Expected configuration cancellation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        let current = await coordinator.currentState
        let cleanup = await probe.cleanupScopes
        XCTAssertEqual(current, state)
        XCTAssertTrue(cleanup.isEmpty)
        try await coordinator.run(kind: .configuration, failureScope: .connection) { _ in }
    }

    func testDisconnectWaitsForConfigurationBeforeCleaningConnection() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let changing = Task {
            try await coordinator.run(kind: .configuration, failureScope: .connection) { _ in
                await probe.markOperationStarted()
                do {
                    try await Task.sleep(nanoseconds: 30000000000)
                } catch {
                    events.append("configuration-finished")
                    throw error
                }
            }
        }
        await waitUntil { await probe.operationStarted }
        await coordinator.disconnect()
        XCTAssertEqual(events.values, ["configuration-finished"])
        let cleanup = await probe.cleanupScopes
        XCTAssertEqual(cleanup, [.connection])
        _ = try? await changing.value
    }

    func testTerminationUnregistersOperationBeforeDisconnectedNotification() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let running = Task {
            try await coordinator.run(kind: .generation, failureScope: .connection) { _ in
                await probe.markOperationStarted()
                try await Task.sleep(nanoseconds: 30000000000)
            }
        }
        await waitUntil { await probe.operationStarted }
        var restarted: Task<Bool, Never>?
        await coordinator.setStateListener { state in
            guard state.connectionState == .idle else { return }
            let gate = DispatchSemaphore(value: 0)
            restarted = Task.detached {
                defer { gate.signal() }
                do {
                    try await coordinator.run(kind: .connection, failureScope: .connection) { _ in }
                    return true
                } catch {
                    return false
                }
            }
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
        }

        await coordinator.disconnect()
        let succeeded = await restarted?.value ?? false
        XCTAssertTrue(succeeded)
        _ = try? await running.value
    }

    func testDisconnectCancelsOperationBeforeConnectingStateIsCommitted()
        async throws {
        for initialState: RealtimeConnectionState in [.idle, .ready] {
            for kind: XmaxRealtimeLifecycleManager.OperationKind in [.connection, .generation] {
                let probe = XmaxRealtimeLifecycleManagerProbe()
                let coordinator = makeCoordinator(probe: probe)
                if initialState == .ready {
                    try await coordinator.run(kind: .media) { token in
                        try await coordinator.commit(RealtimeState(connectionState: .ready), token: token)
                    }
                }
                let initialCleanupCount = await probe.cleanupScopes.count
                let runningTask = Task {
                    try await coordinator.run(
                        kind: kind,
                        failureScope: .connection
                    ) { token in
                        await probe.markOperationStarted()
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                        try await coordinator.commit(
                            RealtimeState(connectionState: .connecting),
                            token: token
                        )
                    }
                }
                await waitUntil { await probe.operationStarted }
                let beforeDisconnect = await coordinator.currentState
                XCTAssertEqual(beforeDisconnect.connectionState, initialState)

                await coordinator.disconnect()

                do {
                    try await runningTask.value
                    XCTFail("Expected pending connection or generation to be cancelled")
                } catch {
                    XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
                }
                let state = await coordinator.currentState
                let cleanupScopes = await probe.cleanupScopes
                XCTAssertEqual(state.connectionState, .idle)
                XCTAssertEqual(
                    Array(cleanupScopes.dropFirst(initialCleanupCount)),
                    [.connection]
                )
            }
        }
    }

    func testDisconnectWithoutConnectionDoesNotCleanUpAgain() async {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)

        await coordinator.disconnect()
        let idleState = await coordinator.currentState
        let idleCleanupScopes = await probe.cleanupScopes
        XCTAssertEqual(idleState.connectionState, .idle)
        XCTAssertTrue(idleCleanupScopes.isEmpty)

        await coordinator.terminate(.connection)
        await coordinator.disconnect()
        let disconnectedState = await coordinator.currentState
        let cleanupScopes = await probe.cleanupScopes
        XCTAssertEqual(disconnectedState.connectionState, .idle)
        XCTAssertEqual(cleanupScopes, [.connection])
    }

    func testDisconnectDoesNotCancelLocalMediaPreparation() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        try await coordinator.run(kind: .media, failureScope: .all) { token in
            try await coordinator.commit(RealtimeState(connectionState: .preparing), token: token)
            await coordinator.disconnect()
            try token.ensureCurrent()
            let state = await coordinator.currentState
            XCTAssertEqual(state.connectionState, .preparing)
            try await coordinator.commit(RealtimeState(connectionState: .ready), token: token)
        }
        let state = await coordinator.currentState
        let cleanupScopes = await probe.cleanupScopes
        XCTAssertEqual(state.connectionState, .ready)
        XCTAssertTrue(cleanupScopes.isEmpty)
    }

    func testCloseDuringDisconnectedNotificationCompletesFullCleanup()
        async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        try await coordinator.run(kind: .connection, failureScope: .connection) { token in
            try await coordinator.commit(
                RealtimeState(connectionState: .connected),
                token: token
            )
        }

        var closeTask: Task<Bool, Never>?
        await coordinator.setStateListener { state in
            guard state.connectionState == .idle,
                  closeTask == nil else {
                return
            }

            // 固定交错顺序：状态通知返回前，确保另一个关闭请求已经进入。
            let callbackGate = DispatchSemaphore(value: 0)
            closeTask = Task.detached {
                let task = Task {
                    await coordinator.terminate(.all)
                }
                let deadline = DispatchTime.now() + 2
                var closeStarted = false
                while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
                    let current = await coordinator.currentState
                    let scopes = await probe.cleanupScopes
                    if current.connectionState == .disconnecting || scopes.contains(.all) {
                        closeStarted = true
                        break
                    }
                    await Task.yield()
                }
                callbackGate.signal()
                await task.value
                return closeStarted
            }
            XCTAssertEqual(callbackGate.wait(timeout: .now() + 3), .success)
        }

        await coordinator.disconnect()
        let closeStarted = await closeTask?.value ?? false
        let scopes = await probe.cleanupScopes
        let state = await coordinator.currentState
        XCTAssertTrue(closeStarted)
        XCTAssertEqual(scopes, [.connection, .all])
        XCTAssertEqual(state.connectionState, .idle)
    }

    func testRejectsOverlappingOperations() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let runningTask = Task {
            try await coordinator.run(
                kind: .connection,
                failureScope: .connection
            ) { _ in
                await probe.markOperationStarted()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        }
        await waitUntil { await probe.operationStarted }

        do {
            _ = try await coordinator.run(
                kind: .generation,
                failureScope: .connection
            ) { _ in
                2
            }
            XCTFail("Expected overlapping operation to be rejected")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Another realtime operation is in progress; " +
                        "wait for it to finish"
                )
            )
        }

        await coordinator.terminate(
            .connection,
            reason: .normal
        )
        _ = try? await runningTask.value

        let cleanupScopes = await probe.cleanupScopes
        let state = await coordinator.currentState
        XCTAssertEqual(cleanupScopes, [.connection])
        XCTAssertEqual(
            state.connectionState,
            .idle
        )
    }

    func testTerminationInvalidatesPendingStateCommit() async throws {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)
        let runningTask = Task {
            try await coordinator.run(
                kind: .connection,
                failureScope: .connection
            ) { token in
                try await coordinator.commit(
                    RealtimeState(connectionState: .connecting),
                    token: token
                )
                await probe.markOperationStarted()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                try await coordinator.commit(
                    RealtimeState(connectionState: .connected),
                    token: token
                )
            }
        }
        await waitUntil { await probe.operationStarted }

        await coordinator.terminate(
            .connection,
            reason: .normal
        )
        _ = try? await runningTask.value

        let state = await coordinator.currentState
        XCTAssertEqual(
            state.connectionState,
            .idle
        )
    }

    func testFatalErrorIsReportedAfterCleanup() async {
        let events = XmaxRealtimeLifecycleManagerEventRecorder()
        let errorManager = XmaxRealtimeErrorManager()
        let coordinator = XmaxRealtimeLifecycleManager(
            errorManager: errorManager,
            cleanup: { scope, _ in
                events.append("cleanup:\(scope.rawValue)")
                return XmaxRealtimeLifecycleManager.CleanupResult()
            }
        )

        await coordinator.setStateListener { state in
            if case .failure(let error) = state.reason { events.append("callback:\(error.code.rawValue)") }
        }
        do {
            let _: Void = try await coordinator.run(
                kind: .generation,
                failureScope: .connection
            ) { _ in
                throw XmaxError(
                    code: .rtcError,
                    message: "fatal"
                )
            }
            XCTFail("Expected fatal operation to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .rtcError)
        }

        XCTAssertEqual(
            events.values,
            ["cleanup:0", "callback:RTC_ERROR"]
        )
        let state = await coordinator.currentState
        XCTAssertEqual(
            state.connectionState,
            .idle
        )
    }

    func testOperationCanArmFailureCleanupScope() async {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let coordinator = makeCoordinator(probe: probe)

        do {
            let _: Void = try await coordinator.run(
                kind: .generation
            ) { token in
                token.setFailureScope(.connection)
                throw XmaxError(
                    code: .rtcError,
                    message: "generation failed"
                )
            }
            XCTFail("Expected generation to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .rtcError)
        }

        let cleanupScopes = await probe.cleanupScopes
        XCTAssertEqual(cleanupScopes, [.connection])
    }

    func testBackgroundFatalErrorInterruptsActiveOperation() async {
        let probe = XmaxRealtimeLifecycleManagerProbe()
        let receivedError = XmaxRealtimeLifecycleManagerErrorRecorder()
        let errorManager = XmaxRealtimeErrorManager()
        let coordinator = XmaxRealtimeLifecycleManager(
            errorManager: errorManager,
            cleanup: { scope, _ in
                await probe.recordCleanup(scope)
                return XmaxRealtimeLifecycleManager.CleanupResult()
            }
        )
        await coordinator.setStateListener { state in
            if case .failure(let error) = state.reason { receivedError.record(error) }
        }
        let runningTask = Task {
            try await coordinator.run(
                kind: .connection,
                failureScope: .connection
            ) { _ in
                await probe.markOperationStarted()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        await waitUntil { await probe.operationStarted }
        let expectedError = XmaxError(
            code: .sessionError,
            message: "session closed"
        )

        await coordinator.terminate(
            with: expectedError,
            target: .connection
        )

        do {
            try await runningTask.value
            XCTFail("Expected active operation to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        let cleanupScopes = await probe.cleanupScopes
        XCTAssertEqual(cleanupScopes, [.connection])
        XCTAssertEqual(receivedError.value, expectedError)
    }
}

private extension XmaxRealtimeLifecycleManagerTests {
    func makeCoordinator(
        probe: XmaxRealtimeLifecycleManagerProbe,
        onStateChanged: (@Sendable (RealtimeState) async -> Void)? = nil
    ) -> XmaxRealtimeLifecycleManager {
        XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            onStateChanged: onStateChanged,
            cleanup: { scope, _ in
                await probe.recordCleanup(scope)
                return XmaxRealtimeLifecycleManager.CleanupResult()
            }
        )
    }

    func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }
}

private actor XmaxRealtimeLifecycleManagerProbe {

    // 操作状态
    private(set) var operationStarted = false

    // 清理记录
    private(set) var cleanupScopes: [
        XmaxRealtimeLifecycleManager.TerminationScope
    ] = []

    func markOperationStarted() {
        operationStarted = true
    }

    func recordCleanup(
        _ scope: XmaxRealtimeLifecycleManager.TerminationScope
    ) {
        cleanupScopes.append(scope)
    }
}

private final class XmaxRealtimeLifecycleManagerEventRecorder: @unchecked Sendable {

    // 并发状态
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }
}

private final class XmaxRealtimeLifecycleManagerErrorRecorder: @unchecked Sendable {

    // 并发状态
    private let lock = NSLock()
    private var error: XmaxError?

    var value: XmaxError? {
        lock.withLock { error }
    }

    func record(_ error: XmaxError) {
        lock.withLock {
            self.error = error
        }
    }
}

private actor LifecycleFailureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
