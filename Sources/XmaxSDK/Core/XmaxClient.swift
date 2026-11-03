//
//  XmaxClient.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A client for account queries, realtime generation, storage, and media services.
public final class XmaxClient: Sendable {

    /// The configuration used by this client.
    public let configuration: XmaxConfiguration

    /// The service for account queries, storage credentials, and media safety checks.
    private let apiService: any ApiServicing

    /// Creates a client with the specified configuration.
    ///
    /// - Parameter configuration: The API credentials, service environment, and logging options.
    public convenience init(
        configuration: XmaxConfiguration
    ) {
        self.init(configuration: configuration, session: .shared)
    }

    /// Creates a client using an injected HTTP session for general API requests.
    init(
        configuration: XmaxConfiguration,
        session: URLSession
    ) {
        self.configuration = configuration
        XmaxLogger.configure(
            options: configuration.loggerOptions,
            language: configuration.environment == .china ? .chinese : .english
        )
        apiService = ApiService(
            apiKey: configuration.apiKey,
            baseURL: configuration.environment.apiBaseURL,
            session: session
        )
    }

    /// Fetches remaining credits for the account owning this client's API key.
    ///
    /// Each call reads the current server balance using the configured general API environment.
    /// Fractional credits are preserved. This query does not create a realtime session.
    ///
    /// - Returns: The account's remaining credits.
    /// - Throws: An `XmaxError` if credentials, transport, or the response are invalid.
    public func getCreditBalance() async throws -> XmaxCreditBalance {
        try configuration.validate()
        let response = try await apiService.get("/balance", as: CreditBalanceResponse.self)
        guard response.currentBalance.isFinite, response.currentBalance >= 0 else {
            throw XmaxError(
                code: .apiError,
                message: "Credit balance must be a finite, nonnegative number"
            )
        }
        return XmaxCreditBalance(currentBalance: response.currentBalance)
    }

    /// The server payload decoded separately from the validated public account model.
    private struct CreditBalanceResponse: Decodable, Sendable {
        /// Remaining credits, validated before returning them to your app.
        let currentBalance: Double
    }

    /// Creates a manager for local media inputs and realtime generation.
    ///
    /// API credentials are validated when connecting, not during manager creation or local preview.
    ///
    /// - Parameter options: The model, frame interpolation, and adaptive quality settings.
    @MainActor
    public func createRealtimeManager(
        options: RealtimeConfiguration
    ) -> any XmaxRealtimeManaging {
        XmaxRealtimeManager(
            options: options,
            apiService: ApiService(
                apiKey: configuration.apiKey,
                baseURL: configuration.environment.realtimeApiBaseURL
            )
        )
    }

    /// Creates a manager for uploading and downloading media files.
    ///
    /// - Throws: An `XmaxError` if the client configuration is invalid.
    public func createStorageManager() throws -> any XmaxStorageManaging {
        try configuration.validate()
        return XmaxStorageManager(apiService: apiService)
    }

    /// Creates a service for media sizing and capability queries.
    ///
    /// - Parameter model: The model whose sizing rules the service uses.
    public func createMediaService(
        model: RealtimeModel = .x2_1
    ) -> any MediaServicing {
        MediaService(model: model)
    }
}
