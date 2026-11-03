//
//  ApiService.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Sends Xmax API requests and handles responses, logging, and errors.
final class ApiService: ApiServicing, Sendable {

    /// The default HTTP timeout, in seconds.
    static let defaultTimeoutInterval: TimeInterval = 15

    /// The API access key.
    private let apiKey: String

    /// The API base URL.
    private let baseURL: URL

    /// The HTTP request timeout, in seconds.
    private let timeoutInterval: TimeInterval

    /// The HTTP URL session.
    private let session: URLSession

    /// Creates an API service.
    ///
    /// - Parameters:
    ///   - apiKey: The API access key.
    ///   - baseURL: The HTTPS API root URL.
    ///   - timeoutInterval: The request timeout, in seconds.
    ///   - session: The URL session performing requests.
    init(
        apiKey: String,
        baseURL: URL,
        timeoutInterval: TimeInterval = ApiService.defaultTimeoutInterval,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval
        self.session = session
    }

    /// Sends an HTTP request and decodes its response.
    ///
    /// - Parameters:
    ///   - method: The request's HTTP method.
    ///   - path: The path relative to the API root.
    ///   - body: The encoded body, or `nil` for no body.
    ///   - responseType: The response decoding type.
    ///
    /// - Returns: The decoded business response.
    ///
    /// - Throws: An error if credentials or URL are invalid, the request is rejected, or transport
    ///   or decoding fails.
    func request<Response: Decodable & Sendable>(
        _ method: ApiMethod,
        path: String,
        body: Data?,
        as responseType: Response.Type
    ) async throws -> Response {
        try validateConfiguration()
        let request = try makeRequest(
            method: method,
            path: path,
            body: body
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch {
            let durationMs = Self.durationMs(since: startedAt)
            ApiLogger.logFailure(
                method: method,
                path: path,
                error: error,
                durationMs: durationMs
            )
            throw Self.transportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let error = XmaxError(
                code: .networkError,
                message: "HTTP request returned a non-HTTP response"
            )
            ApiLogger.logFailure(
                method: method,
                path: path,
                error: error,
                durationMs: Self.durationMs(since: startedAt)
            )
            throw error
        }

        do {
            let value: Response = try Self.parseResponse(
                data,
                statusCode: httpResponse.statusCode,
                as: responseType
            )
            ApiLogger.logResponse(
                method: method,
                path: path,
                statusCode: httpResponse.statusCode,
                bodyByteCount: data.count,
                durationMs: Self.durationMs(since: startedAt),
                successful: true
            )
            return value
        } catch {
            ApiLogger.logResponse(
                method: method,
                path: path,
                statusCode: httpResponse.statusCode,
                bodyByteCount: data.count,
                durationMs: Self.durationMs(since: startedAt),
                successful: false,
                responseBody: data
            )
            if let xmaxError = error as? XmaxError {
                throw xmaxError
            }

            throw XmaxError(
                code: .apiError,
                message: ErrorMessageFormatter.format(error),
                httpStatus: httpResponse.statusCode
            )
        }
    }
}

private extension ApiService {

    /// The metadata shared by Xmax API responses.
    struct EnvelopeMetadata: Decodable {

        /// The API success indicator.
        let success: Bool?

        /// The API business error code.
        let code: Int?

        /// The API business error message.
        let message: String?
    }

    /// A successful Xmax API response.
    struct PayloadEnvelope<Response: Decodable>: Decodable {

        /// The decoded response data.
        let data: Response?
    }

    /// Validates credentials, HTTPS URL, and timeout.
    ///
    /// - Throws: An error if the API key is empty or network configuration is invalid.
    func validateConfiguration() throws {
        guard !apiKey.isEmpty else {
            throw XmaxError(
                code: .invalidAPIKey,
                message: "API key cannot be empty"
            )
        }
        guard baseURL.scheme?.lowercased() == "https",
            baseURL.host != nil,
            timeoutInterval > 0
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "API service configuration is invalid"
            )
        }
    }

    /// Creates an authenticated request with runtime information.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - path: The path relative to the API root; other hosts are not allowed.
    ///   - body: The encoded body, or `nil` for no body.
    ///
    /// - Returns: The configured HTTP request.
    ///
    /// - Throws: A configuration error if the path is empty, invalid, or targets another host.
    func makeRequest(
        method: ApiMethod,
        path: String,
        body: Data?
    ) throws -> URLRequest {
        let normalizedPath = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedPath.isEmpty,
            !normalizedPath.contains("://"),
            !normalizedPath.hasPrefix("//")
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "API request path is invalid"
            )
        }

        let base =
            baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        let relativePath =
            normalizedPath.hasPrefix("/")
            ? normalizedPath
            : "/\(normalizedPath)"
        guard let url = URL(string: base + relativePath),
            url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
            url.host?.lowercased() == baseURL.host?.lowercased()
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "API request path is invalid"
            )
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            apiKey,
            forHTTPHeaderField: "X-Api-Key"
        )

        let runtime = RuntimeInfo.current
        request.setValue(
            runtime.platform,
            forHTTPHeaderField: "X-Platform"
        )
        request.setValue(
            runtime.osVersion,
            forHTTPHeaderField: "X-OS-Version"
        )
        request.setValue(
            runtime.sdkVersion,
            forHTTPHeaderField: "X-SDK-Version"
        )
        request.setValue(
            runtime.deviceModel,
            forHTTPHeaderField: "X-Device-Model"
        )

        return request
    }

    /// Validates response status and decodes business data.
    ///
    /// - Parameters:
    ///   - data: The response body.
    ///   - statusCode: The HTTP response status.
    ///   - as: The business data decoding type.
    ///
    /// - Returns: The decoded business data.
    ///
    /// - Throws: An API error if JSON, status, or response data is invalid.
    static func parseResponse<Response: Decodable>(
        _ data: Data,
        statusCode: Int,
        as _: Response.Type
    ) throws -> Response {
        let metadata: EnvelopeMetadata
        do {
            metadata = try JSONDecoder().decode(
                EnvelopeMetadata.self,
                from: data
            )
        } catch {
            throw XmaxError(
                code: .apiError,
                message: "Server returned invalid JSON",
                httpStatus: statusCode
            )
        }

        guard (200..<300).contains(statusCode),
            metadata.success == true
        else {
            let message = metadata.message?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMessage: String
            if let message, !message.isEmpty {
                resolvedMessage = message
            } else {
                resolvedMessage = "Xmax API request failed"
            }

            throw XmaxError(
                code: .apiError,
                message: resolvedMessage,
                apiCode: metadata.code,
                httpStatus: statusCode
            )
        }

        do {
            let envelope = try JSONDecoder().decode(
                PayloadEnvelope<Response>.self,
                from: data
            )
            guard let value = envelope.data else {
                throw DecodingError.valueNotFound(
                    Response.self,
                    .init(
                        codingPath: [],
                        debugDescription: "API response data is missing"
                    )
                )
            }

            return value
        } catch {
            throw XmaxError(
                code: .apiError,
                message: "Server returned invalid response data",
                httpStatus: statusCode
            )
        }
    }

    /// Converts transport failures to SDK network or cancellation errors.
    ///
    /// - Parameter error: The original network error.
    ///
    /// - Returns: The SDK error preserving cancellation semantics.
    static func transportError(
        _ error: any Error
    ) -> XmaxError {
        if XmaxError.isCancellation(error) {
            return XmaxError(
                code: .cancelled,
                message: "API request was cancelled"
            )
        }

        return XmaxError(
            code: .networkError,
            message: "HTTP request failed: " + ErrorMessageFormatter.format(error)
        )
    }

    /// Returns elapsed time from a monotonic start timestamp.
    ///
    /// - Parameter startedAt: The request's monotonic start time, in nanoseconds.
    ///
    /// - Returns: The elapsed whole milliseconds.
    static func durationMs(
        since startedAt: UInt64
    ) -> Int {
        let elapsedNanoseconds =
            DispatchTime.now().uptimeNanoseconds
            - startedAt
        return Int(elapsedNanoseconds / 1_000_000)
    }
}
