//
//  XmaxError.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A handler for SDK component errors.
typealias XmaxErrorListener = @Sendable (XmaxError) -> Void

/// An error code reported by XmaxSDK.
public enum XmaxErrorCode: String, CaseIterable, Sendable {

    /// The API key is missing or empty.
    case invalidAPIKey = "INVALID_API_KEY"

    /// The arguments, configuration, or lifecycle state do not permit the operation.
    case invalidConfiguration = "INVALID_CONFIGURATION"

    /// An unexpected internal error.
    case internalError = "INTERNAL_ERROR"

    /// A network connection or HTTP request failed.
    case networkError = "NETWORK_ERROR"

    /// The API rejected the request or returned an invalid response.
    case apiError = "API_ERROR"

    /// Session data is missing, the session closed, or its heartbeat failed.
    case sessionError = "SESSION_ERROR"

    /// An RTC engine, room, transport, or rendering error.
    case rtcError = "RTC_ERROR"

    /// A media reading, decoding, synchronization, or frame processing error.
    case mediaError = "MEDIA_ERROR"

    /// Frame interpolation is unsupported by the system, device, or video format.
    case frameInterpolationUnsupported =
        "FRAME_INTERPOLATION_UNSUPPORTED"

    /// Camera access was denied.
    case cameraPermissionDenied = "CAMERA_PERMISSION_DENIED"

    /// Microphone access was denied.
    case microphonePermissionDenied = "MICROPHONE_PERMISSION_DENIED"

    /// A file or data upload failed.
    case uploadError = "UPLOAD_ERROR"

    /// A remote file download failed.
    case downloadError = "DOWNLOAD_ERROR"

    /// The image failed its content safety check.
    case unsafeImage = "UNSAFE_IMAGE"

    /// The operation was cancelled.
    case cancelled = "CANCELLED"

    /// A connection, room event, or generation result timed out.
    case timeout = "TIMEOUT"
}

/// An error thrown or reported by XmaxSDK.
public struct XmaxError: Error, LocalizedError, Equatable, Sendable {

    /// The SDK error code.
    public let code: XmaxErrorCode

    /// A readable error description.
    public let message: String

    /// The API business error code, if returned.
    public let apiCode: Int?

    /// The HTTP status code, if a response was received.
    public let httpStatus: Int?

    /// Creates an SDK error.
    public init(
        code: XmaxErrorCode,
        message: String,
        apiCode: Int? = nil,
        httpStatus: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.apiCode = apiCode
        self.httpStatus = httpStatus
    }

    /// The localized error description.
    public var errorDescription: String? {
        message
    }

    /// Converts an error to an SDK error, preserving cancellation and existing `XmaxError` values.
    ///
    /// - Parameter error: The error to convert.
    ///
    /// - Returns: The SDK error.
    public static func from(
        _ error: any Error
    ) -> XmaxError {
        if let xmaxError = error as? XmaxError {
            return xmaxError
        }

        if isCancellation(error) {
            return XmaxError(
                code: .cancelled,
                message: "Operation was cancelled"
            )
        }

        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? String(describing: error) : description

        return XmaxError(
            code: .internalError,
            message: message
        )
    }

    /// Identifies cancellation from SDK operations, Swift tasks, or URL loading.
    static func isCancellation(
        _ error: any Error
    ) -> Bool {
        switch error {
        case let error as XmaxError:
            error.code == .cancelled
        case is CancellationError:
            true
        case let error as URLError:
            error.code == .cancelled
        default:
            false
        }
    }
}
