//
//  EncodingControllerTests.swift
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

final class EncodingControllerTests: XCTestCase {
    func testDefaultPreferenceMaintainsFramerateThroughResizeAndConfiguration() throws {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)
        let format = RealtimeVideoFormat(width: 832, height: 1472, fps: 30)

        XCTAssertEqual(format.encoderPreference, .maintainFramerate)
        let resized = format.resized(width: 704, height: 1280)
        XCTAssertEqual(resized.encoderPreference, .maintainFramerate)
        try controller.configure(resized)
        XCTAssertEqual(rtcManager.encodingConfigurations.last?.encoderPreference, .maintainFramerate)
    }

    func testConfigureAppliesExplicitBitratesAndEncoderPreference() throws {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)
        let cases: [(
            minimum: Int?, maximum: Int?, preference: RealtimeVideoEncoderPreference,
            expectedMinimum: Int, expectedMaximum: Int,
            expectedPreference: VideoEncodingConfiguration.EncoderPreference
        )] = [
            (1500, 3000, .auto, 1500, 3000, .auto),
            (0, 500, .maintainQuality, 0, 500, .maintainQuality),
            (nil, 4000, .maintainFramerate, 500, 4000, .maintainFramerate),
            (1500, nil, .auto, 1500, 2166, .auto),
            (2000, 2000, .auto, 2000, 2000, .auto),
            (nil, nil, .maintainQuality, 500, 2166, .maintainQuality),
            (nil, 800, .auto, 500, 800, .auto),
            (nil, 100, .auto, 100, 100, .auto),
            (0, 50, .auto, 0, 50, .auto),
            (0, nil, .auto, 0, 2166, .auto)
        ]

        for testCase in cases {
            let format = RealtimeVideoFormat(
                width: 832, height: 1472, fps: 24,
                minimumBitrate: testCase.minimum,
                maximumBitrate: testCase.maximum,
                encoderPreference: testCase.preference
            )
            try controller.configure(format)
            XCTAssertEqual(
                rtcManager.encodingConfigurations.last,
                VideoEncodingConfiguration(
                    width: 832, height: 1472, frameRate: 24,
                    minimumBitrate: testCase.expectedMinimum,
                    maximumBitrate: testCase.expectedMaximum,
                    encoderPreference: testCase.expectedPreference
                )
            )
        }
    }

    func testConfigureRejectsInvalidExplicitAndMergedBitrateRangesBeforeRTC() {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)
        let cases: [(minimum: Int?, maximum: Int?)] = [
            (-1, nil), (nil, -1), (nil, 0), (3000, 1500), (4000, nil), (nil, 99)
        ]

        for testCase in cases {
            XCTAssertThrowsError(try controller.configure(RealtimeVideoFormat(
                width: 832, height: 1472, fps: 24,
                minimumBitrate: testCase.minimum,
                maximumBitrate: testCase.maximum
            ))) { error in
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
        }
        XCTAssertTrue(rtcManager.encodingConfigurations.isEmpty)
    }

    func testConfigureAppliesBudgetToEveryReferencePoint() throws {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)
        let cases = [
            (width: 160, height: 120, fps: 15, minimum: 100, maximum: 100),
            (width: 120, height: 120, fps: 15, minimum: 100, maximum: 100),
            (width: 320, height: 180, fps: 15, minimum: 168, maximum: 168),
            (width: 180, height: 180, fps: 15, minimum: 120, maximum: 120),
            (width: 240, height: 180, fps: 15, minimum: 144, maximum: 144),
            (width: 320, height: 240, fps: 15, minimum: 240, maximum: 240),
            (width: 240, height: 240, fps: 15, minimum: 168, maximum: 168),
            (width: 424, height: 240, fps: 15, minimum: 264, maximum: 264),
            (width: 640, height: 360, fps: 15, minimum: 480, maximum: 480),
            (width: 360, height: 360, fps: 15, minimum: 312, maximum: 312),
            (width: 640, height: 360, fps: 30, minimum: 500, maximum: 720),
            (width: 360, height: 360, fps: 30, minimum: 480, maximum: 480),
            (width: 480, height: 360, fps: 15, minimum: 384, maximum: 384),
            (width: 480, height: 360, fps: 30, minimum: 500, maximum: 588),
            (width: 640, height: 480, fps: 15, minimum: 500, maximum: 600),
            (width: 480, height: 480, fps: 15, minimum: 480, maximum: 480),
            (width: 640, height: 480, fps: 30, minimum: 500, maximum: 900),
            (width: 480, height: 480, fps: 30, minimum: 500, maximum: 720),
            (width: 848, height: 480, fps: 15, minimum: 500, maximum: 732),
            (width: 848, height: 480, fps: 30, minimum: 500, maximum: 1116),
            (width: 640, height: 480, fps: 10, minimum: 480, maximum: 480),
            (width: 1280, height: 720, fps: 15, minimum: 500, maximum: 1356),
            (width: 1280, height: 720, fps: 30, minimum: 500, maximum: 2052),
            (width: 960, height: 720, fps: 15, minimum: 500, maximum: 1092),
            (width: 960, height: 720, fps: 30, minimum: 500, maximum: 1656),
            (width: 1920, height: 1080, fps: 15, minimum: 500, maximum: 2496),
            (width: 1920, height: 1080, fps: 30, minimum: 500, maximum: 3780),
            (width: 1920, height: 1080, fps: 60, minimum: 500, maximum: 3900)
        ]

        for testCase in cases {
            try controller.configure(
                RealtimeVideoFormat(width: testCase.width, height: testCase.height, fps: testCase.fps)
            )
            XCTAssertEqual(
                rtcManager.encodingConfigurations.last,
                VideoEncodingConfiguration(
                    width: testCase.width,
                    height: testCase.height,
                    frameRate: testCase.fps,
                    minimumBitrate: testCase.minimum,
                    maximumBitrate: testCase.maximum
                )
            )
        }
    }

    func testConfigureInterpolatesAndExtrapolatesUploadBitrate() throws {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)
        let cases = [
            (width: 1920, height: 1080, fps: 30, minimum: 500, maximum: 3780),
            (width: 1920, height: 1080, fps: 24, minimum: 500, maximum: 3266),
            (width: 832, height: 1472, fps: 24, minimum: 500, maximum: 2166),
            (width: 1472, height: 832, fps: 24, minimum: 500, maximum: 2166),
            (width: 1024, height: 1920, fps: 30, minimum: 500, maximum: 3619),
            (width: 1024, height: 1920, fps: 24, minimum: 500, maximum: 3127),
            (width: 1024, height: 768, fps: 30, minimum: 500, maximum: 1820),
            (width: 1024, height: 768, fps: 24, minimum: 500, maximum: 1572),
            (width: 1920, height: 1080, fps: 120, minimum: 500, maximum: 7800),
            (width: 3840, height: 2160, fps: 30, minimum: 500, maximum: 15120),
            (width: 120, height: 120, fps: 30, minimum: 100, maximum: 100),
            (width: 1920, height: 1080, fps: 1, minimum: 200, maximum: 200),
            (width: 4, height: 4, fps: 1, minimum: 100, maximum: 100)
        ]

        for testCase in cases {
            try controller.configure(
                RealtimeVideoFormat(width: testCase.width, height: testCase.height, fps: testCase.fps)
            )

            XCTAssertEqual(
                rtcManager.encodingConfigurations.last,
                VideoEncodingConfiguration(
                    width: testCase.width,
                    height: testCase.height,
                    frameRate: testCase.fps,
                    minimumBitrate: testCase.minimum,
                    maximumBitrate: testCase.maximum
                )
            )
        }
    }

    func testBitrateRemainsOrderedAndMonotonicAcrossFrameRateBoundaries() throws {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)

        for (width, height) in [(120, 120), (320, 240), (832, 1472), (1920, 1080), (3840, 2160)] {
            var previousMinimum = 0
            var previousMaximum = 0
            for fps in [1, 9, 10, 11, 14, 15, 16, 24, 29, 30, 31, 59, 60, 61, 120] {
                try controller.configure(RealtimeVideoFormat(width: width, height: height, fps: fps))
                let configuration = try XCTUnwrap(rtcManager.encodingConfigurations.last)
                XCTAssertEqual(configuration.minimumBitrate, min(500, configuration.maximumBitrate))
                XCTAssertGreaterThanOrEqual(configuration.maximumBitrate, configuration.minimumBitrate)
                XCTAssertGreaterThanOrEqual(configuration.minimumBitrate, previousMinimum)
                XCTAssertGreaterThanOrEqual(configuration.maximumBitrate, previousMaximum)
                previousMinimum = configuration.minimumBitrate
                previousMaximum = configuration.maximumBitrate
            }
        }
    }

    func testConfigureRejectsBitrateOverflowBeforeCallingRTC() {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)

        XCTAssertThrowsError(
            try controller.configure(
                RealtimeVideoFormat(width: Int.max - 3, height: Int.max - 3, fps: Int.max)
            )
        ) { error in
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertTrue(rtcManager.encodingConfigurations.isEmpty)
    }

    func testConfigureRejectsInvalidFormatBeforeCallingRTC() {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)

        XCTAssertThrowsError(
            try controller.configure(
                RealtimeVideoFormat(width: 1_023, height: 768, fps: 30)
            )
        ) { error in
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Realtime video width and height must be positive " +
                        "even numbers, and fps must be greater than zero"
                )
            )
        }
        XCTAssertTrue(rtcManager.encodingConfigurations.isEmpty)
    }

    func testConfigurePreservesRTCError() {
        let expectedError = XmaxError(
            code: .rtcError,
            message: "Failed to configure RTC encoding"
        )
        let controller = EncodingController(
            rtcManager: RtcManagingStub(encodingError: expectedError)
        )

        XCTAssertThrowsError(
            try controller.configure(
                RealtimeVideoFormat(width: 1_024, height: 768, fps: 30)
            )
        ) { error in
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
    }

    func testConfigureRejectsEvenDimensionsThatAreNotFourAligned() {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)

        for (width, height) in [(912, 1710), (528, 990), (1282, 720), (2, 2)] {
            XCTAssertThrowsError(try controller.configure(RealtimeVideoFormat(
                width: width,
                height: height,
                fps: 30
            ))) { error in
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
        }
        XCTAssertTrue(rtcManager.encodingConfigurations.isEmpty)
    }

    func testConfigureAcceptsEveryUplinkTierWithModelMinimum() throws {
        let rtcManager = RtcManagingStub()
        let controller = EncodingController(rtcManager: rtcManager)
        let baseline = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
        let minimum = RealtimeModel.x2_1_1_preview_cn.minimumInputPixels

        for level in RealtimeQualityLevel.allCases {
            let format = QualityVideoFormat.resolve(
                baseline,
                level: level,
                downlink: false,
                minimumInputPixels: minimum
            )
            try controller.configure(format)
            let configuration = try XCTUnwrap(rtcManager.encodingConfigurations.last)
            XCTAssertEqual(configuration.width, format.width)
            XCTAssertEqual(configuration.height, format.height)
            XCTAssertTrue(configuration.width.isMultiple(of: 4))
            XCTAssertTrue(configuration.height.isMultiple(of: 4))
            XCTAssertGreaterThanOrEqual(configuration.width * configuration.height, minimum)
        }
        XCTAssertEqual(rtcManager.encodingConfigurations.count, RealtimeQualityLevel.allCases.count)
    }
}
