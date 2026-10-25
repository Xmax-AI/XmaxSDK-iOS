//
//  RoomEventTests.swift
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

final class RoomEventTests: XCTestCase {
    func testContainCanvasAndReturnBudgetAreIndependent() throws {
        let canvas = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
        let target = CGSize(width: 864, height: 1536)
        let start = try decode(RoomEvent.start(
            userID: "user", taskID: "task", videoFormat: canvas,
            targetSize: target, context: RealtimeContext(prompt: "test"), paddingContain: true
        ))
        let params = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual(params["size"] as? [Int], [1024, 1920])
        XCTAssertEqual(params["target_size"] as? [Int], [864, 1536])
        XCTAssertEqual(params["padding"] as? String, "contain")
        XCTAssertEqual(params["min_bitrate"] as? Int, 500)
        let budget = try EncodingBitratePolicy.resolve(RealtimeVideoFormat(width: 864, height: 1536, fps: 24))
        XCTAssertEqual(params["max_bitrate"] as? Int, min(10000, budget.maximum))

        let update = try decode(RoomEvent.changeCondition(
            userID: "user", taskID: "task", videoFormat: canvas,
            context: RealtimeContext(prompt: "new"), paddingContain: true
        ))
        let changed = try XCTUnwrap(update["params"] as? [String: Any])
        XCTAssertEqual(changed["padding"] as? String, "contain")
        XCTAssertNil(changed["target_size"])
        XCTAssertNil(changed["min_bitrate"])
        XCTAssertNil(changed["max_bitrate"])
    }

    func testFaceRestorationIsExplicitForStartAndConditionChanges() throws {
        let format = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
        let context = RealtimeContext(prompt: "outfit", referencePath: "reference.png")
        for enabled in [false, true] {
            let messages = try [
                RoomEvent.start(
                    userID: "user", taskID: "task", videoFormat: format,
                    context: context, faceRestoration: enabled
                ),
                RoomEvent.changeCondition(
                    userID: "user", taskID: "task", videoFormat: format,
                    context: context, faceRestoration: enabled
                )
            ]
            for message in messages {
                let event = try decode(message)
                let params = try XCTUnwrap(event["params"] as? [String: Any])
                XCTAssertEqual(params["face_replace"] as? Bool, enabled)
                XCTAssertNil(params["faceRestoration"])
            }
        }
    }

    func testChangeTargetSizeOnlyUpdatesReturnDimensions() throws {
        let event = try decode(RoomEvent.changeTargetSize(
            userID: "user-id",
            taskID: "task-id",
            targetSize: CGSize(width: 676, height: 1196)
        ))
        XCTAssertEqual(event["event"] as? String, "change_target_size")
        XCTAssertEqual(event["user_id"] as? String, "user-id")
        XCTAssertEqual(event["uid"] as? String, "task-id")
        let params = try XCTUnwrap(event["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["target_size", "min_bitrate", "max_bitrate"])
        XCTAssertEqual(params["min_bitrate"] as? Int, 500)
        XCTAssertEqual(params["target_size"] as? [Int], [676, 1196])
        try assertRuntime(in: event)
    }

    func testDownlinkBitratesStayOrderedAcrossOutputSizes() throws {
        let canvas = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
        for (width, height) in [(224, 224), (448, 448), (676, 1196), (1920, 1080), (3840, 2160)] {
            let size = CGSize(width: width, height: height)
            let budget = try EncodingBitratePolicy.resolve(
                RealtimeVideoFormat(width: width, height: height, fps: 24)
            )
            let messages = try [
                RoomEvent.start(
                    userID: "user", taskID: "task", videoFormat: canvas,
                    targetSize: size, context: RealtimeContext(prompt: "test")
                ),
                RoomEvent.changeTargetSize(userID: "user", taskID: "task", targetSize: size)
            ]
            for message in messages {
                let event = try decode(message)
                let params = try XCTUnwrap(event["params"] as? [String: Any])
                XCTAssertEqual(params["min_bitrate"] as? Int, 500)
                XCTAssertEqual(params["max_bitrate"] as? Int, min(10000, max(500, budget.maximum)))
            }
        }
    }

    func testStartAndChangeConditionSeparateGenerationAndReturnSizes() throws {
        let format = RealtimeVideoFormat(width: 832, height: 1472, fps: 24)
        let target = CGSize(width: 676, height: 1196)
        let context = RealtimeContext(prompt: "test")
        let messages = try [
            RoomEvent.start(userID: "user", taskID: "task", videoFormat: format,
                            targetSize: target, context: context),
            RoomEvent.changeCondition(userID: "user", taskID: "task", videoFormat: format,
                                      targetSize: target, context: context)
        ]
        for message in messages {
            let event = try decode(message)
            let params = try XCTUnwrap(event["params"] as? [String: Any])
            XCTAssertEqual(params["size"] as? [Int], [832, 1472])
            XCTAssertEqual(params["target_size"] as? [Int], [676, 1196])
            XCTAssertEqual(params["face_replace"] as? Bool, false)
            XCTAssertEqual(event["session_uid"] as? String, "task")
            if event["event"] as? String == "start" {
                XCTAssertEqual(params["mirror"] as? Bool, false)
            } else {
                XCTAssertNil(params["mirror"])
            }
        }
    }

    func testStartEventMatchesRoomProtocol() throws {
        let event = try decode(
            RoomEvent.start(
                userID: "user-id",
                taskID: "task-id",
                videoFormat: RealtimeVideoFormat(
                    width: 720,
                    height: 1280,
                    fps: 24
                ),
                context: RealtimeContext(
                    prompt: "a prompt",
                    referencePath: "cos/reference.png"
                )
            )
        )

        XCTAssertEqual(event["event"] as? String, "start")
        XCTAssertEqual(event["user_id"] as? String, "user-id")
        XCTAssertEqual(event["uid"] as? String, "task-id")
        try assertRuntime(in: event)
        let params = try XCTUnwrap(event["params"] as? [String: Any])
        XCTAssertEqual(params["model"] as? String, "default")
        XCTAssertEqual(params["size"] as? [Int], [720, 1280])
        XCTAssertNil(params["padding"])
        XCTAssertNil(params["target_size"])
        XCTAssertEqual(params["prompt"] as? String, "a prompt")
        XCTAssertEqual(
            params["ref_image_path"] as? String,
            "cos/reference.png"
        )
    }

    func testStartEventOmitsMissingReferencePath() throws {
        let event = try decode(
            RoomEvent.start(
                userID: "user-id",
                taskID: "task-id",
                videoFormat: RealtimeVideoFormat(
                    width: 512,
                    height: 512,
                    fps: 24
                ),
                context: RealtimeContext(prompt: "a prompt")
            )
        )
        let params = try XCTUnwrap(event["params"] as? [String: Any])

        XCTAssertNil(params["ref_image_path"])
    }

    func testChangeConditionEventMatchesRoomProtocol() throws {
        let event = try decode(
            RoomEvent.changeCondition(
                userID: "user-id",
                taskID: "task-id",
                videoFormat: RealtimeVideoFormat(
                    width: 720,
                    height: 1280,
                    fps: 24
                ),
                context: RealtimeContext(prompt: "new prompt")
            )
        )

        XCTAssertEqual(event["event"] as? String, "change_condition")
        XCTAssertNil(event["condition_version"])
        let params = try XCTUnwrap(event["params"] as? [String: Any])
        XCTAssertNil(params["padding"])
        XCTAssertNil(params["target_size"])
        try assertRuntime(in: event)
    }

    func testStopTracksAndHeartbeatEventsMatchRoomProtocol() throws {
        let stop = try decode(
            RoomEvent.stop(userID: "user-id", taskID: "task-id")
        )
        let tracks = try decode(
            RoomEvent.tracks(
                userID: "user-id",
                taskID: "task-id",
                points: [
                    RealtimePoint(x: 0.431231, y: 0.56931),
                    RealtimePoint(x: 0, y: 1)
                ]
            )
        )
        let heartbeat = try decode(
            RoomEvent.heartbeat(userID: "user-id")
        )

        XCTAssertEqual(stop["event"] as? String, "stop")
        XCTAssertEqual(stop["user_id"] as? String, "user-id")
        XCTAssertEqual(stop["uid"] as? String, "task-id")
        XCTAssertEqual(tracks["event"] as? String, "tracks")
        XCTAssertEqual(
            tracks["tracks"] as? [[Double]],
            [[0.431231, 0.56931], [0, 1]]
        )
        XCTAssertEqual(heartbeat["event"] as? String, "heartbeat")
        XCTAssertEqual(heartbeat["user_id"] as? String, "user-id")
        try assertRuntime(in: stop)
        try assertRuntime(in: tracks)
        try assertRuntime(in: heartbeat)
    }
}

private extension RoomEventTests {
    func assertRuntime(in event: [String: Any]) throws {
        let runtime = try XCTUnwrap(event["runtime"] as? [String: String])
        XCTAssertEqual(runtime["platform"], "ios")
        XCTAssertEqual(runtime["sdk_version"], XmaxSDKInfo.version)
        XCTAssertFalse(runtime["os_version", default: ""].isEmpty)
        XCTAssertFalse(runtime["device_model", default: ""].isEmpty)
    }

    func decode(_ message: String) throws -> [String: Any] {
        let data = try XCTUnwrap(message.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
