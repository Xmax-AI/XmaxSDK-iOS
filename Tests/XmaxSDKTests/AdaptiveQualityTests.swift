//
//  AdaptiveQualityTests.swift
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

final class AdaptiveQualityTests: XCTestCase {
    private let baseline = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)

    func testTiersAlwaysDeriveFromMediaBaseline() {
        let expected = [(1024, 1920, 30), (896, 1680, 24), (768, 1440, 24), (608, 1140, 20), (512, 960, 16)]
        for (index, value) in expected.enumerated() {
            let format = QualityVideoFormat.resolve(baseline, level: RealtimeQualityLevel.allCases[index], downlink: false)
            XCTAssertEqual(format.width, value.0)
            XCTAssertEqual(format.height, value.1)
            XCTAssertEqual(format.fps, value.2)
            XCTAssertEqual(format.width * baseline.height, format.height * baseline.width)
        }
        XCTAssertEqual(QualityVideoFormat.resolve(baseline, level: .l1, downlink: false), baseline)
    }

    func testSmallInputsAreNotUpscaledAndFrameRateIsOnlyACeiling() {
        let small = RealtimeVideoFormat(width: 160, height: 120, fps: 12)
        for level in RealtimeQualityLevel.allCases {
            let format = QualityVideoFormat.resolve(small, level: level, downlink: false)
            XCTAssertEqual(format.size, small.size)
            XCTAssertEqual(format.fps, 12)
        }
    }

    func testUplinkMinimumAppliesAfterAlignmentWithoutChangingDownlink() {
        let minimum = RealtimeModel.x2_1_1_preview_cn.minimumInputPixels
        let uplink = QualityVideoFormat.resolve(baseline, level: .l5, downlink: false, minimumInputPixels: minimum)
        XCTAssertEqual(uplink.size, CGSize(width: 544, height: 1020))
        XCTAssertEqual(uplink.fps, 16)
        XCTAssertEqual(
            QualityVideoFormat.resolve(baseline, level: .l5, downlink: true, minimumInputPixels: minimum).size,
            CGSize(width: 512, height: 960)
        )
        for (width, height) in [
            (1024, 1920), (1920, 1024), (1080, 1920), (1000, 600), (1000, 500), (400, 1600),
            (708, 708), (544, 1020), (1256, 1672), (1004, 504)
        ] {
            let format = RealtimeVideoFormat(width: width, height: height, fps: 30)
            for level in RealtimeQualityLevel.allCases {
                let resolved = QualityVideoFormat.resolve(format, level: level, downlink: false, minimumInputPixels: minimum)
                XCTAssertGreaterThanOrEqual(resolved.width * resolved.height, minimum)
                XCTAssertLessThanOrEqual(resolved.width, width)
                XCTAssertLessThanOrEqual(resolved.height, height)
                XCTAssertTrue(resolved.width.isMultiple(of: 4))
                XCTAssertTrue(resolved.height.isMultiple(of: 4))
            }
        }
    }

    func testQualityConfigurationRetainsModelMinimumAcrossLevelChanges() {
        let controller = QualityController(rtcManager: RtcManagingStub())
        let minimum = RealtimeModel.x2_1_1_preview_cn.minimumInputPixels
        _ = controller.prepareQuality(
            baseline: baseline,
            model: RealtimeModel.x2_1_1_preview_cn.rawValue,
            minimumInputPixels: minimum,
            isAdaptiveQualityEnabled: false
        )
        controller.completeQuality(downlink: false, level: .l5, success: true)
        XCTAssertEqual(controller.qualityConfiguration?.minimumInputPixels, minimum)
        XCTAssertEqual(controller.qualityConfiguration?.uplink.size, CGSize(width: 544, height: 1020))
    }

    func testDownlinkTierDimensionsRetainExistingAlignment() {
        let expected = [(1024, 1920), (912, 1710), (768, 1440), (608, 1140), (512, 960)]
        for (level, size) in zip(RealtimeQualityLevel.allCases, expected) {
            let format = QualityVideoFormat.resolve(baseline, level: level, downlink: true)
            XCTAssertEqual(format.size, CGSize(width: size.0, height: size.1))
            XCTAssertEqual(format.fps, 24)
        }
    }

    func testExplicitUplinkBitratesAreNotAppliedToDownlink() {
        let custom = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30, minimumBitrate: 1500, maximumBitrate: 3000, encoderPreference: .maintainQuality)
        let up = QualityVideoFormat.resolve(custom, level: .l3, downlink: false)
        let down = QualityVideoFormat.resolve(custom, level: .l3, downlink: true)
        XCTAssertEqual(up.minimumBitrate, 1500)
        XCTAssertEqual(up.maximumBitrate, 3000)
        XCTAssertEqual(up.encoderPreference, .maintainQuality)
        XCTAssertNil(down.minimumBitrate)
        XCTAssertNil(down.maximumBitrate)
        XCTAssertEqual(down.fps, 24)
    }

    func testQualityLevelOnlyAcceptsSupportedRawValues() {
        XCTAssertEqual(RealtimeQualityLevel.allCases.map(\.rawValue), [1, 2, 3, 4, 5])
        XCTAssertNil(RealtimeQualityLevel(rawValue: 0))
        XCTAssertNil(RealtimeQualityLevel(rawValue: 6))
    }

    func testManualCommitStillAllowsAutomaticAdaptationAfterCooldown() {
        var direction = QualityDirection(baseline: baseline, level: .l2, downlink: false)
        direction.complete(level: .l4, success: true, now: 10)
        XCTAssertEqual(direction.level, .l4)
        XCTAssertNil(direction.observe(.bad, sampledAt: 11, now: 11))
        XCTAssertNil(direction.observe(.bad, sampledAt: 14, now: 14))
        XCTAssertNil(direction.observe(.bad, sampledAt: 15, now: 15))
        XCTAssertEqual(direction.observe(.bad, sampledAt: 16, now: 16), .l5)
    }

    func testThreePoorSamplesDowngradeOnlyAfterSuccessfulCommit() {
        var direction = QualityDirection(baseline: baseline, level: .l2, downlink: false)
        XCTAssertNil(direction.observe(.bad, sampledAt: 1, now: 1))
        XCTAssertNil(direction.observe(.veryBad, sampledAt: 2, now: 2))
        XCTAssertEqual(direction.observe(.bad, sampledAt: 3, now: 3), .l3)
        XCTAssertEqual(direction.level, .l2)
        direction.complete(level: .l3, success: false, now: 3)
        XCTAssertEqual(direction.level, .l2)
        XCTAssertNil(direction.observe(.bad, sampledAt: 4, now: 4))
        direction.complete(level: .l3, success: true, now: 5)
        XCTAssertEqual(direction.level, .l3)
    }

    func testFailedUpgradeProbePreventsImmediateOscillation() {
        var direction = QualityDirection(baseline: baseline, level: .l3, downlink: false)
        for time in 1...4 { XCTAssertNil(direction.observe(.good, sampledAt: Double(time), now: Double(time))) }
        XCTAssertEqual(direction.observe(.good, sampledAt: 5, now: 5), .l2)
        direction.complete(level: .l2, success: true, now: 5)
        for time in 9...10 { XCTAssertNil(direction.observe(.bad, sampledAt: Double(time), now: Double(time))) }
        XCTAssertEqual(direction.observe(.bad, sampledAt: 11, now: 11), .l3)
        direction.complete(level: .l3, success: true, now: 11)
        for time in 15...70 { XCTAssertNil(direction.observe(.good, sampledAt: Double(time), now: Double(time))) }
        XCTAssertEqual(direction.observe(.good, sampledAt: 71, now: 71), .l2)
    }

    func testUnknownStaleAndNonMonotonicSamplesDoNotTriggerChanges() {
        var direction = QualityDirection(baseline: baseline, level: .l2, downlink: true)
        XCTAssertNil(direction.observe(.bad, sampledAt: 1, now: 10))
        XCTAssertNil(direction.observe(.bad, sampledAt: 11, now: 11))
        XCTAssertNil(direction.observe(.bad, sampledAt: 11, now: 11))
        XCTAssertNil(direction.observe(.unknown, sampledAt: 12, now: 12))
        XCTAssertNil(direction.observe(.bad, sampledAt: 13, now: 13))
        XCTAssertNil(direction.observe(.bad, sampledAt: 20, now: 20))
        XCTAssertNil(direction.observe(.bad, sampledAt: 21, now: 21))
        XCTAssertEqual(direction.observe(.bad, sampledAt: 22, now: 22), .l3)
    }

    func testUplinkAndDownlinkCanIndependentlyReachL5() {
        var down = QualityDirection(baseline: baseline, level: .l4, downlink: true)
        var up = QualityDirection(baseline: baseline, level: .l4, downlink: false)
        for time in 1...3 {
            let downlinkCandidate = down.observe(.bad, sampledAt: Double(time), now: Double(time))
            XCTAssertEqual(downlinkCandidate, time == 3 ? .l5 : nil)
            let candidate = up.observe(.bad, sampledAt: Double(time), now: Double(time))
            XCTAssertEqual(candidate, time == 3 ? .l5 : nil)
        }
    }

    func testDownlinkSkipsIdenticalDimensionsAtMinimumShortEdge() {
        let small = RealtimeVideoFormat(width: 320, height: 240, fps: 30)
        var down = QualityDirection(baseline: small, level: .l4, downlink: true)
        for time in 1...3 {
            XCTAssertNil(down.observe(.bad, sampledAt: Double(time), now: Double(time)))
        }
    }

    func testHistoryExpiresAndSeparatesModelsAndDirections() throws {
        let name = "xmax-quality-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = QualityHistory(model: "model-a", defaults: defaults)
        XCTAssertEqual(history.read(downlink: true, now: 100), .l2)
        history.write(level: .l4, downlink: true, now: 100)
        XCTAssertEqual(history.read(downlink: true, now: 200), .l4)
        XCTAssertEqual(history.read(downlink: false, now: 200), .l2)
        XCTAssertEqual(QualityHistory(model: "model-b", defaults: defaults).read(downlink: true, now: 200), .l2)
        XCTAssertEqual(history.read(downlink: true, now: 99), .l2)
        XCTAssertEqual(history.read(downlink: true, now: 3700), .l2)
    }

    func testInternalSamplingDoesNotReplacePublicNetworkListener() async {
        let rtc = RtcManagingStub()
        let controller = QualityController(rtcManager: rtc)
        let internalEvent = expectation(description: "adaptive listener")
        let publicEvent = expectation(description: "public listener")
        controller.setAdaptiveQualityListener { _, _ in internalEvent.fulfill() }
        controller.setNetworkQualityListener { _ in publicEvent.fulfill() }
        await controller.onNetworkQuality(uplink: .good, downlink: .bad)
        await fulfillment(of: [internalEvent, publicEvent], timeout: 1)
        controller.resetQuality()
        XCTAssertNil(controller.qualityConfiguration)
    }

    func testDisabledAdaptationStartsAtL1AndManualChangesDoNotOverwriteHistory() throws {
        let name = "xmax-quality-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = QualityHistory(model: "model-a", defaults: defaults)
        history.write(level: .l4, downlink: false)
        history.write(level: .l3, downlink: true)
        let controller = QualityController(rtcManager: RtcManagingStub(), historyDefaults: defaults)

        let initial = controller.prepareQuality(
            baseline: baseline,
            model: "model-a",
            isAdaptiveQualityEnabled: false
        )
        XCTAssertEqual(initial.uplinkLevel, .l1)
        XCTAssertEqual(initial.downlinkLevel, .l1)
        XCTAssertEqual(initial.uplink, baseline)

        controller.completeQuality(downlink: false, level: .l2, success: true)
        controller.completeQuality(downlink: true, level: .l5, success: true)
        XCTAssertEqual(controller.qualityConfiguration?.uplinkLevel, .l2)
        XCTAssertEqual(controller.qualityConfiguration?.downlinkLevel, .l5)
        XCTAssertEqual(history.read(downlink: false), .l4)
        XCTAssertEqual(history.read(downlink: true), .l3)

        controller.resetQuality()
        let reconnected = controller.prepareQuality(
            baseline: baseline,
            model: "model-a",
            isAdaptiveQualityEnabled: false
        )
        XCTAssertEqual(reconnected.uplinkLevel, .l1)
        XCTAssertEqual(reconnected.downlinkLevel, .l1)
    }

    func testEnabledAdaptationUsesAndUpdatesHistory() throws {
        let name = "xmax-quality-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = QualityHistory(model: "model-a", defaults: defaults)
        history.write(level: .l4, downlink: false)
        let controller = QualityController(rtcManager: RtcManagingStub(), historyDefaults: defaults)

        let initial = controller.prepareQuality(
            baseline: baseline,
            model: "model-a",
            isAdaptiveQualityEnabled: true
        )
        XCTAssertEqual(initial.uplinkLevel, .l4)
        XCTAssertEqual(initial.downlinkLevel, .l2)
        controller.completeQuality(downlink: true, level: .l3, success: true)
        XCTAssertEqual(history.read(downlink: true), .l3)
    }
}
