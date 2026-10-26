//
//  XmaxClientTests.swift
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

final class XmaxClientTests: XCTestCase {
    func testLastCreatedClientDeterminesGlobalLogLanguage() {
        defer { XmaxLogger.configure(options: []) }

        for environment in [XmaxEnvironment.global, .china, .global] {
            let client = XmaxClient(
                configuration: XmaxConfiguration(
                    apiKey: "test-key",
                    environment: environment
                )
            )
            withExtendedLifetime(client) {
                XCTAssertEqual(
                    XmaxLogger.localized("分辨率", "Resolution"),
                    environment == .china ? "分辨率" : "Resolution"
                )
            }
        }
    }

    @MainActor
    func testCreateRealtimeManagerReturnsPublicRealtimeInterface() {
        let client = XmaxClient(
            configuration: XmaxConfiguration(apiKey: "test-key")
        )
        let options = RealtimeConfiguration(model: .x2_1)

        let manager: any XmaxRealtimeManaging = client.createRealtimeManager(
            options: options
        )

        XCTAssertEqual(manager.options, options)
    }

    @MainActor
    func testCreateRealtimeManagerAllowsLocalPreviewWithoutAPIKey() {
        let client = XmaxClient(
            configuration: XmaxConfiguration(apiKey: " ")
        )

        let manager = client.createRealtimeManager(
            options: RealtimeConfiguration(model: .x2_1)
        )

        XCTAssertEqual(manager.options.model, .x2_1)
    }

    func testCreateStorageManagerReturnsPublicStorageInterface() throws {
        let client = XmaxClient(
            configuration: XmaxConfiguration(apiKey: "test-key")
        )

        let manager: any XmaxStorageManaging = try client.createStorageManager()

        XCTAssertTrue(manager is XmaxStorageManager)
    }

    func testCreateStorageManagerRejectsInvalidConfiguration() {
        let client = XmaxClient(
            configuration: XmaxConfiguration(apiKey: " ")
        )

        XCTAssertThrowsError(try client.createStorageManager()) { error in
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidAPIKey,
                    message: "API key cannot be empty"
                )
            )
        }
    }
}
