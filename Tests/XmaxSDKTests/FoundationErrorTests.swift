//
//  FoundationErrorTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

final class FoundationErrorTests: XCTestCase {
    func testFromKeepsExistingXmaxError() {
        let expected = XmaxError(
            code: .networkError,
            message: "Connection failed"
        )

        XCTAssertEqual(XmaxError.from(expected), expected)
    }

    func testFromWrapsPlatformError() {
        let platformError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )

        XCTAssertEqual(
            XmaxError.from(platformError),
            XmaxError(
                code: .internalError,
                message: "Request timed out"
            )
        )
    }

    func testFromPreservesSwiftTaskCancellation() {
        XCTAssertEqual(XmaxError.from(CancellationError()).code, .cancelled)
    }

    func testFromPreservesURLSessionCancellation() {
        let errors: [any Error] = [
            URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ]

        for error in errors {
            XCTAssertEqual(XmaxError.from(error).code, .cancelled)
        }
    }

    func testFromDoesNotTreatMatchingCodesInOtherDomainsAsCancellation() {
        let error = NSError(
            domain: "test.media",
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "Media operation failed"]
        )

        XCTAssertEqual(
            XmaxError.from(error),
            XmaxError(code: .internalError, message: "Media operation failed")
        )
    }

    func testFromPreservesOriginalErrorDetails() {
        let original = XmaxError(
            code: .rtcError,
            message: "send failed",
            apiCode: 1003,
            httpStatus: 500
        )
        let error = XmaxError.from(original)

        XCTAssertEqual(error.code, .rtcError)
        XCTAssertEqual(error.message, "send failed")
        XCTAssertEqual(error.apiCode, 1003)
        XCTAssertEqual(error.httpStatus, 500)
    }

    @MainActor
    func testReportingOperationErrorsDoesNotInvokeBackgroundFailureHandler() async {
        let handler = XmaxRealtimeErrorManager()
        let callback = expectation(description: "Operation errors are log-only")
        callback.isInverted = true
        handler.setFailureHandler { _, _, _ in callback.fulfill() }
        let stopError = XmaxError(
            code: .rtcError,
            message: "Stop signal failed"
        )
        let connectionError = XmaxError(
            code: .rtcError,
            message: "RTC connection failed"
        )

        await handler.report(stopError)
        await handler.report(connectionError)

        await fulfillment(of: [callback], timeout: 0.05)
    }

    func testFormatterIncludesXmaxErrorDetails() {
        let error = XmaxError(
            code: .apiError,
            message: "Request rejected",
            apiCode: 1003,
            httpStatus: 400
        )

        XCTAssertEqual(
            ErrorMessageFormatter.format(error),
            "Request rejected（API_ERROR，业务码 1003，HTTP 400）"
        )
    }

    func testFormatterIncludesPlatformErrorCode() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "Network unavailable"]
        )

        XCTAssertEqual(
            ErrorMessageFormatter.format(error),
            "Network unavailable（平台错误码：-1009）"
        )
    }
}
