//
//  XmaxClient.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// A client that provides access to Xmax realtime generation, storage, and media services.
public final class XmaxClient: Sendable {

    /// The configuration used by this client.
    public let configuration: XmaxConfiguration

    /// The service used to request storage credentials and perform media safety checks.
    private let apiService: any ApiServicing

    /// Creates a client with the specified configuration.
    ///
    /// - Parameter configuration: The API credentials, service environment, and logging options.
    public init(
        configuration: XmaxConfiguration
    ) {
        self.configuration = configuration
        XmaxLogger.configure(
            options: configuration.loggerOptions,
            language: configuration.environment == .china ? .chinese : .english
        )
        apiService = ApiService(
            apiKey: configuration.apiKey,
            baseURL: configuration.environment.apiBaseURL
        )
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
