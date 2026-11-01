//
//  RealtimeSessionService.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages session creation, heartbeat, and closure.
final class RealtimeSessionService: RealtimeSessionServicing, @unchecked Sendable {

    /// The session API service.
    private let apiService: any ApiServicing

    /// The RTC provider selected at manager creation.
    private let provider: RtcProvider

    /// The heartbeat interval provider.
    private let heartbeatSleeper: RealtimeHeartbeatSleeper

    /// The lock protecting heartbeat startup and cancellation.
    private let heartbeatLock = NSLock()

    /// The revision rejecting stale heartbeat results.
    private let heartbeatVersion = RealtimeHeartbeatVersion()

    /// The current session heartbeat task.
    private var heartbeatTask: Task<Void, Never>?

    /// Creates a session service with a heartbeat schedule.
    init(
        apiService: any ApiServicing,
        provider: RtcProvider = .agora,
        heartbeatSleeper: RealtimeHeartbeatSleeper = .live
    ) {
        self.apiService = apiService
        self.provider = provider
        self.heartbeatSleeper = heartbeatSleeper
    }

    /// Invalidates and cancels the current heartbeat.
    deinit {
        heartbeatVersion.advance()
        heartbeatTask?.cancel()
    }

    /// Creates a realtime session for the requested model.
    ///
    /// - Parameter model: The realtime generation model.
    ///
    /// - Returns: The server session and its RTC credentials.
    ///
    /// - Throws: An error if the request fails, required fields are missing, or the task is
    ///   cancelled.
    func createSession(
        model: RealtimeModel
    ) async throws -> RealtimeSession {
        let payload = try await apiService.post(
            "/session",
            body: CreateSessionRequest(model: model.rawValue),
            as: SessionPayload.self
        )

        do {
            let session = try Self.makeSession(
                from: payload,
                requiresConnection: true,
                provider: provider
            )
            try Self.ensureSessionActive(session)
            return session
        } catch {
            if let sessionID = Self.nonEmpty(payload.sessionUID) {
                do {
                    try await closeSession(sessionID: sessionID)
                } catch {
                    XmaxLogger.realtime.error(
                        message:
                            "关闭无效会话失败 (Failed to Close Invalid Session)\n└─ \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    /// Starts a session heartbeat, replacing the previous task.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier to keep alive.
    ///   - firstHeartbeatGraceSeconds: The startup allowance sent only in the first request.
    ///   - onFailure: The handler receiving the session identifier and heartbeat error.
    func startHeartbeat(
        sessionID: String,
        firstHeartbeatGraceSeconds: Int? = nil,
        onFailure: @escaping RealtimeSessionHeartbeatFailureHandler
    ) {
        heartbeatLock.withLock {
            let version = heartbeatVersion.advance()
            heartbeatTask?.cancel()

            let context = HeartbeatContext(
                apiService: apiService,
                provider: provider,
                sleeper: heartbeatSleeper,
                versionState: heartbeatVersion,
                version: version,
                sessionID: sessionID,
                firstHeartbeatGraceSeconds: firstHeartbeatGraceSeconds,
                onFailure: onFailure
            )
            heartbeatTask = Task {
                await Self.runHeartbeat(context)
            }
        }
    }

    /// Stops the heartbeat and invalidates pending failure notifications.
    func stopHeartbeat() {
        heartbeatLock.withLock {
            heartbeatVersion.advance()
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    /// Closes a server session.
    ///
    /// - Parameter sessionID: The session identifier to close.
    ///
    /// - Throws: An error if closure fails or the task is cancelled.
    func closeSession(
        sessionID: String
    ) async throws {
        do {
            _ = try await apiService.delete(
                "/session/\(sessionID)",
                as: EmptyResponse.self
            )
        } catch {
            throw XmaxError.from(error)
        }
    }
}

private extension RealtimeSessionService {

    /// The model information in a session creation request.
    struct CreateSessionRequest: Encodable, Sendable {

        /// The model identifier for session creation.
        let model: String
    }

    /// The allowance sent only when generation first becomes ready.
    struct FirstHeartbeatRequest: Encodable, Sendable {
        let firstHeartbeatGraceSeconds: Int
    }

    /// A successful response without business fields.
    struct EmptyResponse: Decodable, Sendable {
    }

    /// The dependencies and validity of a heartbeat loop.
    struct HeartbeatContext: Sendable {

        /// The session heartbeat API service.
        let apiService: any ApiServicing

        /// The transport interpreting refreshed credentials.
        let provider: RtcProvider

        /// The wait for the next heartbeat interval.
        let sleeper: RealtimeHeartbeatSleeper

        /// The current heartbeat validity check.
        let versionState: RealtimeHeartbeatVersion

        /// The heartbeat loop revision.
        let version: UInt64

        /// The session kept alive by this heartbeat.
        let sessionID: String

        /// The measured startup allowance included only in the first heartbeat.
        let firstHeartbeatGraceSeconds: Int?

        /// The session heartbeat failure handler.
        let onFailure: RealtimeSessionHeartbeatFailureHandler
    }

    /// The raw session response fields.
    struct SessionPayload: Decodable, Sendable {

        /// The response session identifier.
        let sessionUID: String?

        /// The response user identifier.
        let userUID: String?

        /// The server-reported session state.
        let status: String?

        /// The RTC connection payload.
        let modelExtra: ModelExtra?

        /// The server session closure reason.
        let closeReason: String?

        /// The mapping from server fields to local properties.
        enum CodingKeys: String, CodingKey {

            /// The session identifier field.
            case sessionUID = "sessionUid"

            /// The server user identifier field.
            case userUID = "userUid"

            /// The session state field.
            case status

            /// The model connection payload field.
            case modelExtra

            /// The session closure reason field.
            case closeReason
        }

        /// Decodes a session response, allowing invalid optional fields to be absent.
        ///
        /// - Parameter decoder: The session response decoder.
        ///
        /// - Throws: A decoding error if a keyed container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionUID = try? container.decode(
                String.self,
                forKey: .sessionUID
            )
            userUID = try? container.decode(
                String.self,
                forKey: .userUID
            )
            status = try? container.decode(
                String.self,
                forKey: .status
            )
            modelExtra = try? container.decode(
                ModelExtra.self,
                forKey: .modelExtra
            )
            closeReason = try? container.decode(
                String.self,
                forKey: .closeReason
            )
        }
    }

    /// An RTC payload supplied as an object or JSON string.
    enum ModelExtra: Decodable, Sendable {

        /// An RTC connection object.
        case object(ConnectionPayload)

        /// RTC connection information encoded as a JSON string.
        case json(String)

        /// An unrecognized connection payload.
        case invalid

        /// Decodes an object or JSON-string RTC payload.
        ///
        /// - Parameter decoder: The payload decoder.
        ///
        /// - Throws: A decoding error if a single-value container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.singleValueContainer()
            if let json = try? container.decode(String.self) {
                self = .json(json)
            } else if let payload = try? ConnectionPayload(from: decoder) {
                self = .object(payload)
            } else {
                self = .invalid
            }
        }
    }

    /// The RTC join credentials and application identifier.
    struct ConnectionPayload: Decodable, Sendable {

        /// The response RTC room identifier.
        let roomID: String?

        /// The RTC room token.
        let token: String?

        /// The local RTC user identifier.
        let userID: String?

        /// The remote user providing generated media.
        let botName: String?

        /// The RTC application identifier.
        let appID: String?

        /// The TRTC user authentication signature.
        let userSig: String?

        /// The TRTC authorization for string-ID rooms.
        let privateMapKey: String?

        /// The mapping from server fields to local properties.
        enum CodingKeys: String, CodingKey {

            /// The TRTC user authentication field.
            case userSig = "user_sig"

            /// The TRTC string-room authorization field.
            case privateMapKey = "private_map_key_with_string_room_id"

            /// The RTC room identifier field.
            case roomID = "room_id"

            /// The RTC token field.
            case token = "room_token"

            /// The local RTC user field.
            case userID = "rtc_user_id"

            /// The remote generation user field.
            case botName = "rtc_bot_id"

            /// The RTC application field.
            case appID = "rtc_app_id"
        }

        /// Decodes RTC credentials, allowing invalid optional fields to be absent.
        ///
        /// - Parameter decoder: The RTC credentials decoder.
        ///
        /// - Throws: A decoding error if a keyed container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userSig = try? container.decode(String.self, forKey: .userSig)
            privateMapKey = try? container.decode(String.self, forKey: .privateMapKey)
            roomID = try? container.decode(
                String.self,
                forKey: .roomID
            )
            token = try? container.decode(
                String.self,
                forKey: .token
            )
            userID = try? container.decode(
                String.self,
                forKey: .userID
            )
            botName = try? container.decode(
                String.self,
                forKey: .botName
            )
            appID = try? container.decode(
                String.self,
                forKey: .appID
            )
        }
    }

    /// Runs a valid session heartbeat until its first reportable failure.
    ///
    /// - Parameter context: The heartbeat session, schedule, and validity.
    static func runHeartbeat(
        _ context: HeartbeatContext
    ) async {
        var firstRequest = true
        while context.versionState.isCurrent(context.version) {
            do {
                if !firstRequest { try await context.sleeper.sleep() }
                try Task.checkCancellation()
                guard context.versionState.isCurrent(context.version) else {
                    return
                }

                let session = try await heartbeatSession(
                    sessionID: context.sessionID,
                    apiService: context.apiService,
                    provider: context.provider,
                    firstHeartbeatGraceSeconds: firstRequest ? context.firstHeartbeatGraceSeconds : nil
                )
                guard context.versionState.isCurrent(context.version) else {
                    return
                }
                try ensureSessionActive(session)
                firstRequest = false
            } catch {
                guard context.versionState.invalidate(context.version) else {
                    return
                }
                await context.onFailure(
                    context.sessionID,
                    XmaxError.from(error)
                )
                return
            }
        }
    }

    /// Sends one heartbeat and decodes the latest session state.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier to keep alive.
    ///   - apiService: The heartbeat API service.
    ///
    /// - Returns: The latest server session state.
    ///
    /// - Throws: An error if the request or response is invalid or the task is cancelled.
    static func heartbeatSession(
        sessionID: String,
        apiService: any ApiServicing,
        provider: RtcProvider,
        firstHeartbeatGraceSeconds: Int? = nil
    ) async throws -> RealtimeSession {
        let payload: SessionPayload
        if let firstHeartbeatGraceSeconds {
            guard firstHeartbeatGraceSeconds >= 0 else {
                throw XmaxError(code: .invalidConfiguration, message: "firstHeartbeatGraceSeconds must be non-negative")
            }
            payload = try await apiService.put(
                "/session/\(sessionID)/heartbeat",
                body: FirstHeartbeatRequest(firstHeartbeatGraceSeconds: firstHeartbeatGraceSeconds),
                as: SessionPayload.self
            )
        } else {
            payload = try await apiService.put(
                "/session/\(sessionID)/heartbeat",
                as: SessionPayload.self
            )
        }
        return try makeSession(
            from: payload,
            requiresConnection: false,
            provider: provider
        )
    }

    /// Checks whether the server has ended a session.
    ///
    /// - Parameter session: The session to check.
    ///
    /// - Throws: A session error if a nonempty state is not `ACTIVE`.
    static func ensureSessionActive(
        _ session: RealtimeSession
    ) throws {
        guard let status = session.status, status != "ACTIVE" else {
            return
        }
        throw XmaxError(
            code: .sessionError,
            message: session.closeReason
                ?? "Session is no longer active: \(status)"
        )
    }

    /// Validates required response fields and creates a session.
    ///
    /// - Parameters:
    ///   - payload: The raw session response.
    ///   - requiresConnection: Whether complete RTC credentials are required.
    ///
    /// - Returns: The validated session.
    ///
    /// - Throws: A session error if its identifier or required RTC credentials are invalid.
    static func makeSession(
        from payload: SessionPayload,
        requiresConnection: Bool,
        provider: RtcProvider
    ) throws -> RealtimeSession {
        guard let sessionID = nonEmpty(payload.sessionUID) else {
            throw XmaxError(
                code: .sessionError,
                message: "Invalid session response"
            )
        }

        let userID = nonEmpty(payload.userUID)
        let connection = makeConnection(from: payload.modelExtra, provider: provider)
        if requiresConnection, connection == nil {
            throw XmaxError(
                code: .sessionError,
                message: "Session does not contain complete RTC join information"
            )
        }

        return RealtimeSession(
            id: sessionID,
            userID: userID,
            status: nonEmpty(payload.status),
            connection: connection,
            closeReason: nonEmpty(payload.closeReason)
        )
    }

    /// Resolves RTC credentials and validates their application identifier.
    ///
    /// - Parameter modelExtra: The RTC object or JSON-string payload.
    ///
    /// - Returns: The valid credentials for this application, or `nil`.
    static func makeConnection(
        from modelExtra: ModelExtra?,
        provider: RtcProvider
    ) -> RealtimeSessionConnection? {
        let payload: ConnectionPayload
        switch modelExtra {
        case .object(let value):
            payload = value
        case .json(let value):
            guard let data = value.data(using: .utf8),
                let value = try? JSONDecoder().decode(
                    ConnectionPayload.self,
                    from: data
                )
            else {
                return nil
            }
            payload = value
        case .invalid, nil:
            return nil
        }

        guard let roomID = nonEmpty(payload.roomID),
            let userID = nonEmpty(payload.userID),
            let botName = nonEmpty(payload.botName),
            let appID = nonEmpty(payload.appID)
        else {
            return nil
        }

        let credentials: RtcCredentials
        switch provider {
        case .agora:
            guard appID == RtcEngineManager.defaultAppID,
                let token = nonEmpty(payload.token)
            else {
                return nil
            }
            credentials = .agora(token: token)
        case .trtc:
            guard let sdkAppID = UInt32(appID), sdkAppID > 0,
                let userSig = nonEmpty(payload.userSig),
                let privateMapKey = nonEmpty(payload.privateMapKey)
            else {
                return nil
            }
            credentials = .trtc(sdkAppID: sdkAppID, userSig: userSig, privateMapKey: privateMapKey)
        }

        return RealtimeSessionConnection(
            roomID: roomID,
            userID: userID,
            credentials: credentials,
            botName: botName
        )
    }

    /// Returns nonempty text after trimming surrounding whitespace.
    ///
    /// - Parameter value: The optional string to normalize.
    ///
    /// - Returns: The nonempty string, or `nil` if no usable text remains.
    static func nonEmpty(
        _ value: String?
    ) -> String? {
        let normalized = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized?.isEmpty == false ? normalized : nil
    }
}

/// An asynchronous wait between heartbeats.
struct RealtimeHeartbeatSleeper: Sendable {

    /// The cancellable heartbeat wait.
    let sleep: @Sendable () async throws -> Void

    /// A heartbeat wait using a 10-second interval.
    static let live = RealtimeHeartbeatSleeper {
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }
}

/// The revision invalidating results from stopped heartbeats.
private final class RealtimeHeartbeatVersion: @unchecked Sendable {

    /// The lock protecting heartbeat revision updates.
    private let lock = NSLock()

    /// The current heartbeat revision.
    private var value: UInt64 = 0

    /// Advances the revision to invalidate previous heartbeats.
    ///
    /// - Returns: The new revision.
    @discardableResult
    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    /// Checks whether a heartbeat revision remains current.
    ///
    /// - Parameter version: The heartbeat revision to check.
    ///
    /// - Returns: `true` if the revision is current.
    func isCurrent(
        _ version: UInt64
    ) -> Bool {
        lock.withLock {
            value == version
        }
    }

    /// Invalidates a heartbeat only if its revision is current.
    ///
    /// - Parameter version: The revision to invalidate.
    ///
    /// - Returns: `true` if the current revision was invalidated; `false` if stale.
    func invalidate(
        _ version: UInt64
    ) -> Bool {
        lock.withLock {
            guard value == version else {
                return false
            }
            value &+= 1
            return true
        }
    }
}
