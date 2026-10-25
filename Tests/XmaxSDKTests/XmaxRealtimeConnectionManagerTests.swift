//
//  XmaxRealtimeConnectionManagerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import UIKit
import XCTest
@testable import XmaxSDK

@MainActor
final class XmaxRealtimeConnectionManagerTests: XCTestCase {
    func testConnectCreatesSessionJoinsRoomAndPublishesLocalMedia() async throws {
        let rtcManager = RtcManagingStub()
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )
        let format = RealtimeVideoFormat(
            width: 720,
            height: 1280,
            fps: 24
        )

        let stream = try await components.manager.connect(
            model: .x2_1_1_preview_cn,
            videoFormat: format,
            includeLocalAudio: true,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )

        XCTAssertEqual(stream.id, StreamID.remote.rawValue)
        XCTAssertEqual(stream.videoTrack?.id, "bot-user")
        XCTAssertEqual(stream.videoTrack?.videoFormat, format)
        let currentSessionID = await components.manager.currentSessionID
        XCTAssertEqual(currentSessionID, "session-id")
        XCTAssertEqual(
            rtcManager.calls,
            [
                .joinRoom(
                    RoomJoinConfiguration(
                        roomID: "room-id",
                        userID: "user-id",
                        token: "room-token"
                    )
                ),
                .publishLocalVideo,
                .publishLocalAudio
            ]
        )
        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1_1_preview_cn),
                .startHeartbeat("session-id")
            ]
        )
        let track = try XCTUnwrap(stream.videoTrack)
        XCTAssertNotNil(VideoRenderRegistry.binding(for: track))
        XCTAssertNotNil(TrajectoryRegistry.binding(for: track))

        _ = try await components.manager.disconnect()
    }

    func testRemoteTrackBindingRendersSelectedRtcStream() async throws {
        let rtcManager = RtcManagingStub()
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: RealtimeSessionServicingStub(session: session)
        )
        let stream = try await components.manager.connect(
            model: .x2_1_1_preview_cn,
            videoFormat: videoFormat,
            includeLocalAudio: false,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )
        let view = XmaxRealtimeVideoView(
            track: stream.videoTrack,
            videoContentMode: .fit
        )
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        window.addSubview(view)
        let remoteStream = RemoteStream(
            roomID: "room-id",
            userID: "bot-user"
        )

        try components.renderController.setRemoteStream(remoteStream)

        XCTAssertEqual(
            rtcManager.calls.last,
            .setRemoteVideoFrameListener(remoteStream, enabled: true)
        )
        _ = try await components.manager.disconnect()
        XCTAssertTrue(
            rtcManager.calls.contains(
                .setRemoteVideoFrameListener(
                    remoteStream,
                    enabled: false
                )
            )
        )
    }

    func testDisconnectStopsHeartbeatAndReleasesConnectionResources() async throws {
        let rtcManager = RtcManagingStub()
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )
        let stream = try await components.manager.connect(
            model: .x2_1_1_preview_cn,
            videoFormat: videoFormat,
            includeLocalAudio: true,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )
        let track = try XCTUnwrap(stream.videoTrack)

        let disconnectedSessionID = try await components.manager.disconnect()
        let currentSessionID = await components.manager.currentSessionID

        XCTAssertEqual(disconnectedSessionID, "session-id")
        XCTAssertEqual(currentSessionID, "")
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
        XCTAssertNil(TrajectoryRegistry.binding(for: track))
        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1_1_preview_cn),
                .startHeartbeat("session-id"),
                .stopHeartbeat,
                .closeSession("session-id")
            ]
        )
        XCTAssertEqual(
            Array(rtcManager.calls.suffix(3)),
            [.unpublishLocalAudio, .unpublishLocalVideo, .leaveRoom]
        )
    }

    func testConnectionFailureRollsBackRoomAndClosesSession() async {
        let publicationError = XmaxError(
            code: .rtcError,
            message: "publish failed"
        )
        let rtcManager = RtcManagingStub(
            publishLocalVideoError: publicationError
        )
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )

        do {
            _ = try await components.manager.connect(
                model: .x2_1_1_preview_cn,
                videoFormat: videoFormat,
                targetSize: CGSize(width: 702, height: 1242),
                includeLocalAudio: false,
                isCurrent: { true },
                onHeartbeatFailure: { _, _ in }
            )
            XCTFail("Expected local publication to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                publicationError
            )
        }

        let targetSize = await components.manager.currentTargetSize
        XCTAssertNil(targetSize)

        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1_1_preview_cn),
                .stopHeartbeat,
                .closeSession("session-id")
            ]
        )
        XCTAssertEqual(
            rtcManager.calls,
            [
                .joinRoom(
                    RoomJoinConfiguration(
                        roomID: "room-id",
                        userID: "user-id",
                        token: "room-token"
                    )
                ),
                .publishLocalVideo,
                .leaveRoom
            ]
        )
    }

    func testCancelledConnectionClosesLateSessionWithoutJoiningRoom() async {
        let rtcManager = RtcManagingStub()
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )

        do {
            _ = try await components.manager.connect(
                model: .x2_1_1_preview_cn,
                videoFormat: videoFormat,
                includeLocalAudio: false,
                isCurrent: { false },
                onHeartbeatFailure: { _, _ in }
            )
            XCTFail("Expected stale connection to be cancelled")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .cancelled,
                    message: "Realtime connection was cancelled"
                )
            )
        }

        XCTAssertTrue(rtcManager.calls.isEmpty)
        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1_1_preview_cn),
                .closeSession("session-id")
            ]
        )
    }

    func testTargetSizeChangesKeepTrajectoryOverlayOnResolvedMediaSize() async throws {
        let components = makeManager(
            sessionService: RealtimeSessionServicingStub(session: session)
        )
        let stream = try await components.manager.connect(
            model: .x2_1_1_preview_cn,
            videoFormat: videoFormat,
            targetSize: CGSize(width: 1024, height: 1920),
            includeLocalAudio: false,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )
        let track = try XCTUnwrap(stream.videoTrack)
        let binding = try XCTUnwrap(TrajectoryRegistry.binding(for: track))
        let overlay = TrajectoryOverlayView(renderer: DefaultTrajectoryEffectRenderer())
        overlay.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        binding.attach(to: overlay, contentMode: .fit)

        XCTAssertEqual(track.videoFormat?.size, CGSize(width: 1024, height: 1920))
        XCTAssertTrue(overlay.point(inside: CGPoint(x: 5, y: 320), with: nil))
        XCTAssertTrue(overlay.point(inside: CGPoint(x: 180, y: 5), with: nil))

        await components.manager.updateTargetSize(CGSize(width: 360, height: 360), videoFormat: videoFormat)

        XCTAssertEqual(track.videoFormat?.size, CGSize(width: 360, height: 360))
        XCTAssertTrue(overlay.point(inside: CGPoint(x: 5, y: 320), with: nil))
        XCTAssertTrue(overlay.point(inside: CGPoint(x: 180, y: 5), with: nil))
        _ = try await components.manager.disconnect()
    }

    func testUpdatingRemoteVideoFormatUpdatesActiveTrack() async throws {
        let components = makeManager(
            sessionService: RealtimeSessionServicingStub(session: session)
        )
        let stream = try await components.manager.connect(
            model: .x2_1_1_preview_cn,
            videoFormat: videoFormat,
            includeLocalAudio: false,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )
        let updatedFormat = RealtimeVideoFormat(
            width: 540,
            height: 960,
            fps: 15
        )

        await components.manager.updateRemoteVideoFormat(updatedFormat)

        XCTAssertEqual(stream.videoTrack?.videoFormat, updatedFormat)
        _ = try await components.manager.disconnect()
    }
}

private extension XmaxRealtimeConnectionManagerTests {
    struct Components {
        let manager: XmaxRealtimeConnectionManager
        let renderController: RenderController
    }

    var session: RealtimeSession {
        RealtimeSession(
            id: "session-id",
            userID: "user-id",
            status: "ACTIVE",
            connection: RealtimeSessionConnection(
                roomID: "room-id",
                userID: "user-id",
                token: "room-token",
                botName: "bot-user"
            ),
            closeReason: nil
        )
    }

    var videoFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(width: 720, height: 1280, fps: 24)
    }

    func makeManager(
        rtcManager: RtcManagingStub = RtcManagingStub(),
        sessionService: RealtimeSessionServicingStub
    ) -> Components {
        let renderController = RenderController(
            rtcManager: rtcManager
        )
        let streamController = StreamController(
            rtcManager: rtcManager
        )
        return Components(
            manager: XmaxRealtimeConnectionManager(
                interactionController: InteractionController(),
                renderController: renderController,
                streamController: streamController,
                sessionService: sessionService
            ),
            renderController: renderController
        )
    }
}
