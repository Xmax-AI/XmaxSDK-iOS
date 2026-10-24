//
//  MediaServiceTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import XCTest
@testable import XmaxSDK

final class MediaServiceTests: XCTestCase {
    func testGenerationSizeSelectsBucketsByAspectRatioRatherThanExactDimensions() throws {
        let service = MediaService()
        for (mediaSize, expectedCanvas) in [
            (CGSize(width: 1200, height: 1600), CGSize(width: 1024, height: 1920)),
            (CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1024)),
            (CGSize(width: 1024, height: 1920), CGSize(width: 1024, height: 1920)),
            (CGSize(width: 1920, height: 1024), CGSize(width: 1920, height: 1024)),
            (CGSize(width: 1200, height: 1500), CGSize(width: 1024, height: 1920)),
            (CGSize(width: 1156, height: 1536), CGSize(width: 1024, height: 1920))
        ] {
            XCTAssertEqual(try service.resolveGenerationSize(mediaSize), expectedCanvas)
        }
    }

    func testLargeImagesAndVideosShareModelAreaLimitWithoutMatchingBuckets() throws {
        let service = MediaService()
        let cases = [
            (CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080)),
            (CGSize(width: 2160, height: 3840), CGSize(width: 1080, height: 1920)),
            (CGSize(width: 8000, height: 6000), CGSize(width: 1664, height: 1248)),
            (CGSize(width: 6000, height: 8000), CGSize(width: 1248, height: 1664))
        ]
        for source in [RealtimeMediaSource.image, .video] {
            for (original, expected) in cases {
                let size = try service.resolveMediaSize(original, source: source)
                XCTAssertEqual(size, expected)
                XCTAssertTrue(Int(size.width).isMultiple(of: 4))
                XCTAssertTrue(Int(size.height).isMultiple(of: 4))
                XCTAssertLessThanOrEqual(size.width * size.height, CGFloat(service.model.maximumInputPixels))
                XCTAssertEqual(size.width * original.height, size.height * original.width)
            }
        }
    }

    func testMediaSizePreservesValidInputsWithoutApplyingCanvasAlignment() throws {
        let service = MediaService()
        for source in [RealtimeMediaSource.image, .video] {
            for size in [CGSize(width: 1000, height: 500), CGSize(width: 1004, height: 600)] {
                XCTAssertEqual(try service.resolveMediaSize(size, source: source), size)
            }
            XCTAssertEqual(
                try service.resolveMediaSize(CGSize(width: 1001, height: 1000), source: source),
                CGSize(width: 1000, height: 1000)
            )
            XCTAssertEqual(
                try service.resolveMediaSize(CGSize(width: 1001, height: 600), source: source),
                CGSize(width: 1000, height: 600)
            )
        }
    }

    func testSmallMediaIsUpscaledForEveryNonCameraSource() throws {
        let cases = [
            (CGSize(width: 400, height: 752), CGSize(width: 600, height: 1128)),
            (CGSize(width: 752, height: 400), CGSize(width: 1128, height: 600)),
            (CGSize(width: 512, height: 960), CGSize(width: 544, height: 1020)),
            (CGSize(width: 640, height: 480), CGSize(width: 832, height: 624)),
            (CGSize(width: 1, height: 1), CGSize(width: 708, height: 708))
        ]

        for model in RealtimeModel.allCases {
            let service = MediaService(model: model)
            XCTAssertEqual(model.minimumInputPixels, 500000)
            for source in [RealtimeMediaSource.image, .video, .external] {
                for (original, expected) in cases {
                    let size = try service.resolveMediaSize(
                        original,
                        source: source
                    )
                    XCTAssertEqual(size, expected)
                    XCTAssertGreaterThanOrEqual(size.width * size.height, CGFloat(model.minimumInputPixels))
                    XCTAssertLessThanOrEqual(size.width * size.height, CGFloat(model.maximumInputPixels))
                    XCTAssertEqual(size.width * original.height, size.height * original.width)
                    XCTAssertTrue(Int(size.width).isMultiple(of: 4))
                    XCTAssertTrue(Int(size.height).isMultiple(of: 4))
                }
                XCTAssertEqual(
                    try service.resolveMediaSize(CGSize(width: 1001, height: 500), source: source),
                    CGSize(width: 1000, height: 500)
                )
                XCTAssertEqual(
                    try service.resolveMediaSize(CGSize(width: 512, height: 1000), source: source),
                    CGSize(width: 512, height: 1000)
                )
            }
        }
    }

    func testMediaAlignmentKeepsTheMinimumWhenExactRatioCannotFit() throws {
        for model in RealtimeModel.allCases {
            let service = MediaService(model: model)
            for source in [RealtimeMediaSource.image, .video, .external] {
                for original in [
                    CGSize(width: 1001, height: 499),
                    CGSize(width: 999, height: 500),
                    CGSize(width: 1000, height: 500)
                ] {
                    for size in [original, CGSize(width: original.height, height: original.width)] {
                        let resolved = try service.resolveMediaSize(
                            size,
                            source: source
                        )
                        let expected = size.width > size.height
                            ? CGSize(width: 1000, height: 500)
                            : CGSize(width: 500, height: 1000)
                        XCTAssertEqual(resolved, expected)
                        XCTAssertGreaterThanOrEqual(resolved.width * resolved.height, CGFloat(model.minimumInputPixels))
                        XCTAssertLessThanOrEqual(resolved.width * resolved.height, CGFloat(model.maximumInputPixels))
                    }
                }
            }
        }
    }

    func testMediaAreaLimitsHoldForExtremeRatiosAndAlignmentBoundaries() throws {
        let cases = [
            CGSize(width: 1, height: 500001),
            CGSize(width: 707, height: 708),
            CGSize(width: 999, height: 501),
            CGSize(width: 1449, height: 1450),
            CGSize(width: 65535, height: 65537)
        ]

        for model in RealtimeModel.allCases {
            let service = MediaService(model: model)
            for original in cases {
                for size in [original, CGSize(width: original.height, height: original.width)] {
                    let resolved = try service.resolveMediaSize(
                        size,
                        source: .external
                    )
                    XCTAssertGreaterThanOrEqual(resolved.width * resolved.height, CGFloat(model.minimumInputPixels))
                    XCTAssertLessThanOrEqual(resolved.width * resolved.height, CGFloat(model.maximumInputPixels))
                    XCTAssertTrue(Int(resolved.width).isMultiple(of: 4))
                    XCTAssertTrue(Int(resolved.height).isMultiple(of: 4))
                }
            }
        }
    }

    func testUpscaledMediaDoesNotImposeTheInputMinimumOnTargetSize() throws {
        let service = MediaService()
        let media = try service.resolveMediaSize(
            CGSize(width: 512, height: 960),
            source: .video
        )
        let target = try service.resolveTargetSize(
            media,
            maximumSize: CGSize(width: media.width / 2, height: media.height / 2),
            frameInterpolationEnabled: false
        )

        XCTAssertEqual(media, CGSize(width: 544, height: 1020))
        XCTAssertEqual(target, CGSize(width: 256, height: 480))
        XCTAssertLessThan(target.width * target.height, CGFloat(service.model.minimumInputPixels))
    }

    func testCameraBucketValidationOccursBeforeAreaScaling() {
        XCTAssertThrowsError(try MediaService().resolveMediaSize(CGSize(width: 2048, height: 3840), source: .camera)) { error in
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
    }

    func testMediaSizeRejectsInvalidDimensions() {
        for source in RealtimeMediaSource.allCases {
            for width: CGFloat in [.nan, .infinity, 0, -1, 100.5, CGFloat(Int.max)] {
                for size in [CGSize(width: width, height: 600), CGSize(width: 600, height: width)] {
                    XCTAssertThrowsError(try MediaService().resolveMediaSize(size, source: source))
                }
            }
        }
    }

    func testMediaFourAlignmentAvoidsAdditionalTargetRoundingAtFullTier() throws {
        let service = MediaService()
        for source in [RealtimeMediaSource.image, .video] {
            for (original, expected) in [
                (CGSize(width: 1280, height: 1707), CGSize(width: 1252, height: 1672)),
                (CGSize(width: 1707, height: 1280), CGSize(width: 1672, height: 1252)),
                (CGSize(width: 6000, height: 8000), CGSize(width: 1248, height: 1664))
            ] {
                let media = try service.resolveMediaSize(original, source: source)
                XCTAssertEqual(media, expected)
                let target = try service.resolveTargetSize(media, maximumSize: media, frameInterpolationEnabled: false)
                XCTAssertEqual(target, media)
                XCTAssertLessThanOrEqual(media.width * media.height, CGFloat(service.model.maximumInputPixels))
            }
        }
    }

    func testBucketResolutionsArePreservedInBothOrientations() throws {
        let service = MediaService(model: .x2_1_1_preview_cn)
        for size in service.model.supportedVideoFormats.map(\.size) {
            XCTAssertEqual(try service.resolveMediaSize(size, source: .camera), size)
        }
    }

    func testBucketRejectsOtherSizesWithoutResizingOrRounding() {
        let service = MediaService(model: .x2_1_1_preview_cn)
        let sizes: [CGSize] = [
            CGSize(width: 832, height: 1472),
            CGSize(width: 1080, height: 1920),
            CGSize(width: 512, height: 960),
            CGSize(width: 2048, height: 3840),
            CGSize(width: 1120, height: 1120),
            CGSize(width: 1024, height: 1919.9),
            CGSize(width: 0, height: 1920),
            CGSize(width: CGFloat.nan, height: 1920),
            CGSize(width: CGFloat.infinity, height: 1920)
        ]
        for size in sizes {
            XCTAssertThrowsError(try service.resolveMediaSize(size, source: .camera)) { error in
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
        }
    }

    func testInterpolationTargetIsIndependentOfInputBuckets() throws {
        let target = try MediaService(model: .x2_1_1_preview_cn).resolveTargetSize(
            CGSize(width: 1024, height: 1920),
            maximumSize: CGSize(width: 1024, height: 1920),
            frameInterpolationEnabled: true
        )
        XCTAssertEqual(target, CGSize(width: 672, height: 1260))
    }

    func testInterpolationSizePreservesExactAspectRatioWithinPixelBudget() throws {
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 720, height: 1280), CGSize(width: 684, height: 1216)),
            (CGSize(width: 832, height: 1472), CGSize(width: 676, height: 1196)),
            (CGSize(width: 1024, height: 1920), CGSize(width: 672, height: 1260)),
            (CGSize(width: 1120, height: 1120), CGSize(width: 948, height: 948)),
            (CGSize(width: 704, height: 1280), CGSize(width: 660, height: 1200)),
            (CGSize(width: 1472, height: 832), CGSize(width: 1196, height: 676)),
            (CGSize(width: 640, height: 480), CGSize(width: 640, height: 480)),
            (CGSize(width: 1000, height: 900), CGSize(width: 1000, height: 900))
        ]
        for (source, expected) in cases {
            let target = try MediaService().resolveTargetSize(source, maximumSize: source, frameInterpolationEnabled: true)
            XCTAssertEqual(target, expected)
            XCTAssertEqual(target.width * source.height, target.height * source.width)
            XCTAssertLessThanOrEqual(target.width * target.height, 900000)
            XCTAssertLessThanOrEqual(target.width, source.width)
            XCTAssertLessThanOrEqual(target.height, source.height)
            XCTAssertTrue(Int(target.width).isMultiple(of: 4))
            XCTAssertTrue(Int(target.height).isMultiple(of: 4))
        }
    }

    func testInterpolationSizeRejectsInvalidDimensions() {
        for width: CGFloat in [.nan, .infinity, 0, -1, 704.5, CGFloat(Int.max)] {
            XCTAssertThrowsError(try MediaService().resolveTargetSize(
                CGSize(width: width, height: 1280),
                maximumSize: CGSize(width: 720, height: 1280),
                frameInterpolationEnabled: true
            )) { error in
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
        }
    }

    func testInterpolationSizeAllowsSmallRatioErrorWhenExactAlignmentIsUnavailable() throws {
        let cases = [
            (CGSize(width: 1001, height: 1000), CGSize(width: 948, height: 948)),
            (CGSize(width: 802, height: 600), CGSize(width: 800, height: 600)),
            (CGSize(width: 600, height: 802), CGSize(width: 600, height: 800))
        ]
        for (source, expected) in cases {
            let target = try MediaService().resolveTargetSize(source, maximumSize: source, frameInterpolationEnabled: true)
            XCTAssertEqual(target, expected)
            XCTAssertLessThanOrEqual(target.width * target.height, 900000)
            let ratioError = abs(target.width * source.height / (target.height * source.width) - 1)
            XCTAssertLessThan(ratioError, 0.01)
        }
    }

    func testInterpolationSizeRejectsDimensionsTooSmallForFourAlignment() {
        for size in [CGSize(width: 2, height: 600), CGSize(width: 600, height: 2)] {
            XCTAssertThrowsError(try MediaService().resolveTargetSize(size, maximumSize: size, frameInterpolationEnabled: true)) { error in
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
        }
    }

    func testTargetSizeAppliesBoundsProportionallyAndDoesNotUpscale() throws {
        let service = MediaService()
        let source = CGSize(width: 720, height: 1280)
        XCTAssertEqual(
            try service.resolveTargetSize(source, maximumSize: CGSize(width: 800, height: 1600), frameInterpolationEnabled: false),
            source
        )
        XCTAssertEqual(
            try service.resolveTargetSize(source, maximumSize: CGSize(width: 600, height: 800), frameInterpolationEnabled: false),
            CGSize(width: 432, height: 768)
        )
    }

    func testTargetSizeRejectsInvalidMaximumSize() {
        let source = CGSize(width: 720, height: 1280)
        for invalid: CGFloat in [.nan, .infinity, 0, -1] {
            for bounds in [CGSize(width: invalid, height: 1280), CGSize(width: 720, height: invalid)] {
                XCTAssertThrowsError(try MediaService().resolveTargetSize(source, maximumSize: bounds, frameInterpolationEnabled: false))
            }
        }
    }

    func testModelDefaultCameraResolutionIsPreserved() throws {
        for model in RealtimeModel.allCases {
            let format = model.defaultCameraVideoFormat
            let source = CGSize(width: format.width, height: format.height)
            let size = try MediaService(model: model).resolveMediaSize(source, source: .camera)
            XCTAssertEqual(size, source)
        }
    }

    func testPreviewModelCameraBuckets() throws {
        for model in [RealtimeModel.x2_1_1_preview_cn, .x2_1_1_preview_us] {
            let service = MediaService(model: model)
            for size in [CGSize(width: 1024, height: 1920), CGSize(width: 1920, height: 1024)] {
                XCTAssertEqual(try service.resolveMediaSize(size, source: .camera), size)
                XCTAssertEqual(try service.resolveGenerationSize(size), size)
            }
            for size in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 1408, height: 1408)] {
                XCTAssertThrowsError(try service.resolveMediaSize(size, source: .camera)) { error in
                    XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
                }
            }
            XCTAssertEqual(
                try service.resolveGenerationSize(CGSize(width: 720, height: 1280)),
                CGSize(width: 1024, height: 1920)
            )
        }
    }

    func testFrameInterpolationRejectsInvalidVideoSize() {
        let service = MediaService()

        XCTAssertFalse(service.supportsFrameInterpolation(
            for: CGSize(width: CGFloat.nan, height: 1_280)
        ))
        XCTAssertFalse(service.supportsFrameInterpolation(
            for: CGSize(width: 704.5, height: 1_280)
        ))
        XCTAssertFalse(service.supportsFrameInterpolation(
            for: CGSize(width: 0, height: 1_280)
        ))
    }

    func testFrameInterpolationVideoSizeUses900000PixelLimit() {
        XCTAssertFalse(MediaService.supportsFrameInterpolationSize(
            CGSize(width: 704, height: 1280)
        ))
        XCTAssertTrue(MediaService.supportsFrameInterpolationSize(
            CGSize(width: 702, height: 1242)
        ))
        XCTAssertTrue(MediaService.supportsFrameInterpolationSize(
            CGSize(width: 1000, height: 900)
        ))
        XCTAssertFalse(MediaService.supportsFrameInterpolationSize(
            CGSize(width: 1000, height: 901)
        ))
        XCTAssertFalse(MediaService.supportsFrameInterpolationSize(
            CGSize(width: 992, height: 992)
        ))
        XCTAssertFalse(MediaService.supportsFrameInterpolationSize(
            CGSize(width: 1120, height: 840)
        ))
        XCTAssertFalse(MediaService.supportsFrameInterpolationSize(
            CGSize(width: 1120, height: 1120)
        ))
    }

#if targetEnvironment(simulator)
    func testFrameInterpolationIsUnavailableInSimulator() {
        XCTAssertFalse(
            MediaService().supportsFrameInterpolation(
                for: CGSize(width: 704, height: 1_280)
            )
        )
    }
#endif
}
