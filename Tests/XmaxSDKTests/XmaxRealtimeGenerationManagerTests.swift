//
//  XmaxRealtimeGenerationManagerTests.swift
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
final class XmaxRealtimeGenerationManagerTests: XCTestCase {
    func testStartWaitsForFirstFrameBeforeSubscribingRemoteAudio() async throws {
        let render = RenderControllingStub()
        let gate = GenerationFrameGate()
        render.frameReadyHandler = { await gate.wait() }
        let components = try await makeComponents(renderController: render)
        let start = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "first frame"),
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(stream: remoteStream)
        for _ in 0..<1_000 {
            if await gate.isWaiting { break }
            await Task.yield()
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        XCTAssertEqual(render.frameReadyWaitCount, 1)
        XCTAssertFalse(components.rtcManager.calls.contains(.subscribeRemoteAudio(userID: "bot-user", subscribe: true)))
        await gate.release()
        let taskID = try await start.value
        XCTAssertTrue(components.rtcManager.calls.contains(.subscribeRemoteAudio(userID: "bot-user", subscribe: true)))
        try await components.manager.stop(taskID: taskID)
        await components.roomController.leave()
    }

    func testFirstFrameFailureStopsGenerationWithoutCachingConditions() async throws {
        let render = RenderControllingStub()
        let failure = XmaxError(code: .timeout, message: "First frame timed out")
        render.frameReadyHandler = { throw failure }
        let components = try await makeComponents(renderController: render)
        let start = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "must not be cached"),
                faceRestoration: true,
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(stream: remoteStream)
        do {
            _ = try await start.value
            XCTFail("Expected first-frame failure")
        } catch {
            XCTAssertEqual(error as? XmaxError, failure)
        }
        await waitForEvent("stop", rtcManager: components.rtcManager)
        let restoration = await components.manager.cachedFaceRestoration
        XCTAssertFalse(restoration)
        do {
            try await components.manager.validateContext(nil)
            XCTFail("Failed startup must not cache generation conditions")
        } catch {
            XCTAssertEqual(XmaxError.from(error).code, .invalidConfiguration)
        }
        await components.roomController.leave()
    }

    func testTrajectoryBasisIsIndependentOfCanvasPaddingAndReturnSize() async throws {
        for contain in [false, true] {
            let components = try await makeComponents()
            let start = Task {
                try await components.manager.start(
                    videoFormat: videoFormat,
                    targetSize: CGSize(width: 684, height: 1216),
                    context: RealtimeContext(prompt: "initial"),
                    generationVideoFormat: RealtimeVideoFormat(width: 1024, height: 1920, fps: 30),
                    paddingContain: contain,
                    ensureCurrent: {}
                )
            }
            await waitForEvent("start", rtcManager: components.rtcManager)
            components.rtcManager.emitRemoteVideoAvailable(stream: remoteStream)
            let taskID = try await start.value

            let targetSizes = [CGSize(width: 684, height: 1216), CGSize(width: 704, height: 1244), CGSize(width: 1024, height: 1920)]
            for (index, targetSize) in targetSizes.enumerated() {
                if index > 0 {
                    try await components.manager.update(
                        taskID: taskID,
                        videoFormat: videoFormat,
                        targetSize: targetSize,
                        context: RealtimeContext(prompt: "updated"),
                        paddingContain: contain
                    )
                }
                await components.interactionController.submitInteraction(InteractionFrame(
                    points: [CGPoint(x: 90, y: 160)],
                    viewportSize: CGSize(width: 360, height: 640),
                    contentMode: .fit
                ))
                await waitForEventCount("tracks", count: index + 1, rtcManager: components.rtcManager)
                let event = try XCTUnwrap(decodedEvents(components.rtcManager).last { $0["event"] as? String == "tracks" })
                XCTAssertEqual(event["tracks"] as? [[Double]], [[0.25, 0.25]], "Contain: \(contain), target: \(targetSize)")
            }
            try await components.manager.stop(taskID: taskID)
            await components.roomController.leave()
        }
    }

    func testFaceRestorationCanChangeWithCachedContextAndDefaultsBackToFalse() async throws {
        let components = try await makeComponents()
        let context = RealtimeContext(prompt: "cached", referencePath: "reference.png")
        let start = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: context,
                faceRestoration: true,
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(stream: remoteStream)
        let taskID = try await start.value
        let initiallyEnabled = await components.manager.cachedFaceRestoration
        XCTAssertTrue(initiallyEnabled)

        try await components.manager.update(
            taskID: taskID, videoFormat: videoFormat, context: nil,
            faceRestoration: true
        )
        try await components.manager.update(
            taskID: taskID, videoFormat: videoFormat, context: nil
        )
        let events = decodedEvents(components.rtcManager).filter {
            ["start", "change_condition"].contains($0["event"] as? String ?? "")
        }
        XCTAssertEqual(events.count, 3)
        let params = try events.map { try XCTUnwrap($0["params"] as? [String: Any]) }
        XCTAssertEqual(params.compactMap { $0["face_replace"] as? Bool }, [true, true, false])
        XCTAssertTrue(params.allSatisfy { $0["prompt"] as? String == "cached" })
        XCTAssertTrue(params.allSatisfy { $0["ref_image_path"] as? String == "reference.png" })
        let finallyEnabled = await components.manager.cachedFaceRestoration
        XCTAssertFalse(finallyEnabled)
        try await components.manager.reset(taskID: taskID)
        await components.roomController.leave()
    }

    func testFailedUpdateDoesNotOverwriteCachedFaceRestoration() async throws {
        let components = try await makeComponents()
        let start = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "first"),
                faceRestoration: true,
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(stream: remoteStream)
        let taskID = try await start.value

        do {
            try await components.manager.update(
                taskID: taskID, videoFormat: videoFormat, context: nil,
                faceRestoration: false,
                ensureCurrent: { throw CancellationError() }
            )
            XCTFail("Expected cancelled update")
        } catch is CancellationError {}
        let enabled = await components.manager.cachedFaceRestoration
        XCTAssertTrue(enabled)
        try await components.manager.reset(taskID: taskID)
        let resetEnabled = await components.manager.cachedFaceRestoration
        XCTAssertFalse(resetEnabled)
        await components.roomController.leave()
    }

    func testStartSendsSignalAndWaitsForRemotePublication() async throws {
        let components = try await makeComponents()
        let context = RealtimeContext(prompt: "first prompt")

        let startTask = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: context,
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: remoteStream)

        let taskID = try await startTask.value

        XCTAssertEqual(taskID, "task-fixed")
        XCTAssertEqual(components.remoteStreams.values, [remoteStream])
        let startEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).first {
                $0["event"] as? String == "start"
            }
        )
        XCTAssertEqual(startEvent["uid"] as? String, "task-fixed")
        try await components.manager.stop(taskID: taskID)
        await components.roomController.leave()
    }

    func testStartTimeoutStopsTaskAndSendsStopSignal() async throws {
        let components = try await makeComponents(
            timing: StreamGenerationTiming(
                timeoutNanoseconds: 0
            )
        )

        do {
            _ = try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "prompt"),
                ensureCurrent: {}
            )
            XCTFail("Expected generation start to time out")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .timeout,
                    message: "Realtime generation start timed out"
                )
            )
        }

        XCTAssertEqual(
            decodedEvents(components.rtcManager).compactMap {
                $0["event"] as? String
            },
            ["start", "stop"]
        )
        XCTAssertNil(components.remoteStreams.values.last ?? nil)
        await components.roomController.leave()
    }

    func testUpdateReusesTaskWithoutAddingUnspecifiedFields() async throws {
        let components = try await makeComponents()
        let startTask = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "first"),
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: remoteStream)
        let taskID = try await startTask.value

        try await components.manager.update(
            taskID: taskID,
            videoFormat: videoFormat,
            context: RealtimeContext(prompt: "second")
        )
        try await components.manager.update(
            taskID: taskID,
            videoFormat: videoFormat,
            context: RealtimeContext(prompt: "third")
        )

        let changes = decodedEvents(components.rtcManager).filter {
            $0["event"] as? String == "change_condition"
        }
        XCTAssertTrue(changes.allSatisfy { $0["condition_version"] == nil })
        XCTAssertTrue(
            changes.allSatisfy { $0["uid"] as? String == taskID }
        )
        try await components.manager.stop(taskID: taskID)
        await components.roomController.leave()
    }

    func testStopClearsRemoteStreamAndSendsActualTaskID() async throws {
        let components = try await makeComponents()
        let startTask = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "prompt"),
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: remoteStream)
        let taskID = try await startTask.value

        try await components.manager.stop(taskID: taskID)

        XCTAssertNil(components.remoteStreams.values.last ?? nil)
        let stopEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).last {
                $0["event"] as? String == "stop"
            }
        )
        XCTAssertEqual(stopEvent["uid"] as? String, taskID)
        await components.roomController.leave()
    }

    func testGenerationEnablesTracksAndStopDisablesThem() async throws {
        let components = try await makeComponents()
        let startTask = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "prompt"),
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: remoteStream)
        let taskID = try await startTask.value
        let frame = InteractionFrame(
            points: [CGPoint(x: 180, y: 320)],
            viewportSize: CGSize(width: 360, height: 640),
            contentMode: .fit
        )

        await components.interactionController.submitInteraction(frame)
        await waitForEvent("tracks", rtcManager: components.rtcManager)

        let tracksEvent = try XCTUnwrap(
            decodedEvents(components.rtcManager).last {
                $0["event"] as? String == "tracks"
            }
        )
        XCTAssertEqual(tracksEvent["uid"] as? String, taskID)
        XCTAssertEqual(
            tracksEvent["tracks"] as? [[Double]],
            [[0.5, 0.5]]
        )

        try await components.manager.stop(taskID: taskID)
        await components.interactionController.submitInteraction(frame)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            decodedEvents(components.rtcManager).filter {
                $0["event"] as? String == "tracks"
            }.count,
            1
        )
        await components.roomController.leave()
    }

    func testFirstGenerationRequiresContext() async throws {
        let components = try await makeComponents()

        do {
            _ = try await components.manager.start(
                videoFormat: videoFormat,
                context: nil,
                ensureCurrent: {}
            )
            XCTFail("Expected first generation to require context")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "A realtime context is required for the first " +
                        "generation"
                )
            )
        }
        XCTAssertTrue(components.rtcManager.generationMessages.isEmpty)
        await components.roomController.leave()
    }

    func testStoppedGenerationReusesContextUntilReset() async throws {
        let components = try await makeComponents()
        let firstStart = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: RealtimeContext(prompt: "cached prompt"),
                faceRestoration: true,
                ensureCurrent: {}
            )
        }
        await waitForEvent("start", rtcManager: components.rtcManager)
        components.rtcManager.emitRemoteVideoAvailable(
            stream: remoteStream)
        let firstTaskID = try await firstStart.value
        try await components.manager.stop(taskID: firstTaskID)
        components.rtcManager.emitRoomMessage(
            sender: remoteStream.userID,
            message: #"{"event":"video_stopped","uid":"\#(firstTaskID)"}"#
        )
        let cachedFaceRestoration = await components.manager.cachedFaceRestoration
        XCTAssertTrue(cachedFaceRestoration)

        let secondStart = Task {
            try await components.manager.start(
                videoFormat: videoFormat,
                context: nil,
                faceRestoration: cachedFaceRestoration,
                ensureCurrent: {}
            )
        }
        await waitForEventCount(
            "start",
            count: 2,
            rtcManager: components.rtcManager
        )
        components.rtcManager.emitRemoteVideoAvailable(
            stream: remoteStream)
        let secondTaskID = try await secondStart.value
        let starts = decodedEvents(components.rtcManager).filter { $0["event"] as? String == "start" }
        XCTAssertEqual(starts.compactMap { ($0["params"] as? [String: Any])?["face_replace"] as? Bool }, [true, true])
        try await components.manager.reset(taskID: secondTaskID)

        do {
            _ = try await components.manager.start(
                videoFormat: videoFormat,
                context: nil,
                ensureCurrent: {}
            )
            XCTFail("Expected reset to clear cached context")
        } catch {
            XCTAssertEqual(
                (error as? XmaxError)?.code,
                .invalidConfiguration
            )
        }
        await components.roomController.leave()
    }

    func testTaskIDUsesCompactBase64URLTokenAndOSSuffix() {
        let first = XmaxRealtimeGenerationManager.createTaskID()
        let second = XmaxRealtimeGenerationManager.createTaskID()
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
                "abcdefghijklmnopqrstuvwxyz0123456789-_"
        )

        XCTAssertTrue(first.hasPrefix("task-"))
        XCTAssertTrue(first.hasSuffix("?os=ios"))
        XCTAssertEqual(first.count, 34)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(
            first.dropFirst(5).dropLast(7).unicodeScalars.allSatisfy {
                allowed.contains($0)
            }
        )
    }
}

private actor GenerationFrameGate {
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

private extension XmaxRealtimeGenerationManagerTests {
    struct Components {
        let manager: XmaxRealtimeGenerationManager
        let interactionController: InteractionController
        let roomController: RoomController
        let rtcManager: RtcManagingStub
        let remoteStreams: RemoteStreamRecorder
    }

    var videoFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(width: 720, height: 1280, fps: 24)
    }

    var remoteStream: RemoteStream {
        RemoteStream(roomID: "room-id", userID: "bot-user")
    }

    func makeComponents(
        renderController: RenderControllingStub = RenderControllingStub(),
        timing: StreamGenerationTiming = StreamGenerationTiming(
            timeoutNanoseconds: 1_000_000_000
        )
    ) async throws -> Components {
        let rtcManager = RtcManagingStub()
        let roomController = RoomController(rtcManager: rtcManager)
        try await roomController.join(
            connection: RealtimeSessionConnection(
                roomID: "room-id",
                userID: "user-id",
                token: "room-token",
                botName: "bot-user"
            ),
            ensureActive: {}
        )
        let remoteStreams = RemoteStreamRecorder()
        let streamController = StreamController(
            rtcManager: rtcManager,
            roomController: roomController,
            encodingController: EncodingController(rtcManager: rtcManager),
            qualityController: QualityController(rtcManager: rtcManager),
            remoteStreamListener: { stream in
                remoteStreams.append(stream)
            },
            generationTiming: timing
        )
        try streamController.configureRoom(
            roomID: "room-id",
            botName: "bot-user"
        )
        let interactionController = InteractionController {
            taskID,
            points in
            try await streamController.sendTracks(
                taskID: taskID,
                points: points
            )
        }
        return Components(
            manager: XmaxRealtimeGenerationManager(
                interactionController: interactionController,
                streamController: streamController,
                renderController: renderController,
                taskIDGenerator: { "task-fixed" }
            ),
            interactionController: interactionController,
            roomController: roomController,
            rtcManager: rtcManager,
            remoteStreams: remoteStreams
        )
    }

    func waitForEvent(
        _ event: String,
        rtcManager: RtcManagingStub
    ) async {
        for _ in 0..<1_000 {
            if decodedEvents(rtcManager).contains(where: {
                $0["event"] as? String == event
            }) {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for room event: \(event)")
    }

    func waitForEventCount(
        _ event: String,
        count: Int,
        rtcManager: RtcManagingStub
    ) async {
        for _ in 0..<1_000 {
            let currentCount = decodedEvents(rtcManager).filter {
                $0["event"] as? String == event
            }.count
            if currentCount >= count {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for room event count: \(event)")
    }

    func decodedEvents(
        _ rtcManager: RtcManagingStub
    ) -> [[String: Any]] {
        rtcManager.generationMessages.compactMap { message in
            guard let data = message.data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        }
    }
}

private final class RemoteStreamRecorder: @unchecked Sendable {

    // 并发状态
    private let lock = NSLock()
    private var storedValues: [RemoteStream?] = []

    var values: [RemoteStream?] {
        lock.withLock { storedValues }
    }

    func append(_ stream: RemoteStream?) {
        lock.withLock {
            storedValues.append(stream)
        }
    }
}

private extension RtcManagingStub {
    var generationMessages: [String] {
        calls.compactMap { call in
            guard case .sendRoomMessage(let message) = call else {
                return nil
            }
            return message
        }
    }
}
