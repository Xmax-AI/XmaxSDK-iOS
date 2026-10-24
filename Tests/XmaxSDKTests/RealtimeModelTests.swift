//
//  RealtimeModelTests.swift
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

final class RealtimeModelTests: XCTestCase {
    func testOnlyRegionalPreviewModelsAreAvailable() {
        XCTAssertEqual(RealtimeModel.allCases, [.x2_1_1_preview_cn, .x2_1_1_preview_us])
        XCTAssertNil(RealtimeModel(rawValue: "x2.0"))
        XCTAssertNil(RealtimeModel(rawValue: "x2.1"))
    }

    func testPreviewModelCameraFormats() {
        let models: [RealtimeModel] = [.x2_1_1_preview_cn, .x2_1_1_preview_us]
        XCTAssertEqual(models.map(\.rawValue), ["x2.1.1-preview-cn", "x2.1.1-preview-us"])
        XCTAssertEqual(models.map(\.displayName), ["X2.1.1-preview-cn", "X2.1.1-preview-us"])

        for model in models {
            XCTAssertEqual(model.defaultFrameRate, 30)
            XCTAssertEqual(model.minimumInputPixels, 200000)
            XCTAssertEqual(model.maximumInputPixels, 2100000)
            XCTAssertEqual(model.inputSizeAlignment, 32)
            XCTAssertEqual(
                model.defaultCameraVideoFormat,
                RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
            )
            XCTAssertEqual(model.supportedVideoFormats, [
                RealtimeVideoFormat(width: 1024, height: 1920, fps: 30),
                RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)
            ])
        }
    }

    func testContextNormalizesPromptAndReferencePath() {
        XCTAssertEqual(
            RealtimeContext(
                prompt: "  animate this  ",
                referencePath: "  /image.png  "
            ),
            RealtimeContext(
                prompt: "animate this",
                referencePath: "/image.png"
            )
        )
        XCTAssertNil(
            RealtimeContext(prompt: "prompt", referencePath: " \n ")
                .referencePath
        )
    }

    func testVideoFormatRequiresPositiveEvenDimensions() throws {
        XCTAssertNoThrow(
            try RealtimeVideoFormat(width: 720, height: 1280, fps: 30)
                .validate()
        )

        XCTAssertThrowsError(
            try RealtimeVideoFormat(width: 721, height: 1280, fps: 30)
                .validate()
        ) { error in
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertThrowsError(
            try RealtimeVideoFormat(width: 720, height: 1280, fps: 0)
                .validate()
        ) { error in
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
    }

    func testVideoTrackUpdatesReadableMetadata() {
        let emptyTrack = RealtimeVideoTrack(id: "empty-track")
        let track = RealtimeVideoTrack(
            id: "track-1",
            videoFormat: RealtimeVideoFormat(
                width: 720,
                height: 1280,
                fps: 30
            ),
            position: .front
        )

        track.updateVideoFormat(
            RealtimeVideoFormat(
                width: 1080,
                height: 1920,
                fps: 24
            )
        )
        track.updatePosition(.back)

        XCTAssertEqual(track.id, "track-1")
        XCTAssertEqual(
            track.videoFormat,
            RealtimeVideoFormat(width: 1080, height: 1920, fps: 24)
        )
        XCTAssertEqual(track.position, .back)
        XCTAssertNil(emptyTrack.videoFormat)
        XCTAssertNil(emptyTrack.position)
    }

    func testRealtimeEnumRawValuesMatchCrossPlatformContract() {
        XCTAssertEqual(RealtimeModel.x2_1_1_preview_cn.rawValue, "x2.1.1-preview-cn")
        XCTAssertEqual(RealtimeConnectionState.generating.rawValue, "Generating")
        XCTAssertEqual(RealtimeNetworkQualityLevel.veryBad.rawValue, "VeryBad")
        XCTAssertEqual(RealtimePerformanceStatus.recovered.rawValue, "Recovered")
    }
}
