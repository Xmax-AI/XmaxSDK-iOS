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
    func testOnlyX21ModelIsAvailable() {
        XCTAssertEqual(RealtimeModel.allCases, [.x2_1])
        XCTAssertNil(RealtimeModel(rawValue: "x2.0"))
        XCTAssertNil(RealtimeModel(rawValue: "x2.1.1-preview-cn"))
        XCTAssertNil(RealtimeModel(rawValue: "x2.1.1-preview-us"))
    }

    func testX21ModelCameraFormats() {
        let models = RealtimeModel.allCases
        XCTAssertEqual(models.map(\.rawValue), ["x2.1"])
        XCTAssertEqual(models.map(\.displayName), ["X2.1"])

        for model in models {
            XCTAssertEqual(model.defaultFrameRate, 30)
            XCTAssertEqual(model.minimumInputPixels, 200000)
            XCTAssertEqual(model.maximumInputPixels, 2100000)
            XCTAssertEqual(model.inputSizeAlignment, 32)
            XCTAssertEqual(
                model.defaultCameraVideoFormat,
                RealtimeVideoFormat(width: 1080, height: 1920, fps: 30)
            )
            XCTAssertEqual(model.supportedVideoFormats, [
                RealtimeVideoFormat(width: 1920, height: 1080, fps: 30),
                RealtimeVideoFormat(width: 1080, height: 1920, fps: 30),
                RealtimeVideoFormat(width: 1408, height: 1408, fps: 30),
                RealtimeVideoFormat(width: 1152, height: 1536, fps: 30),
                RealtimeVideoFormat(width: 1536, height: 1152, fps: 30)
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
        XCTAssertEqual(RealtimeModel.x2_1.rawValue, "x2.1")
        XCTAssertEqual(RealtimeConnectionState.generating.rawValue, "Generating")
        XCTAssertEqual(RealtimeNetworkQualityLevel.veryBad.rawValue, "VeryBad")
        XCTAssertEqual(RealtimePerformanceStatus.recovered.rawValue, "Recovered")
    }
}
