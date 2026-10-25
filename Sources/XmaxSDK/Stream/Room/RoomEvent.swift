//
//  RoomEvent.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The structured signaling exchanged through RTC rooms.
enum RoomEvent {

    /// Encodes a generation start signal with runtime information.
    ///
    /// - Parameters:
    ///   - userID: The local RTC account.
    ///   - taskID: The generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve input aspect ratio within the canvas.
    ///
    /// - Returns: The JSON generation start message.
    ///
    /// - Throws: An error if generation parameters, bitrate resolution, or JSON encoding fails.
    static func start(
        userID: String,
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) throws -> String {
        try encode(
            StartPayload(
                params: GenerationParameters(
                    videoFormat: videoFormat,
                    targetSize: targetSize,
                    context: context,
                    faceRestoration: faceRestoration,
                    paddingContain: paddingContain,
                    mirror: false
                ),
                userID: userID,
                taskID: taskID
            )
        )
    }

    /// Encodes a condition update with runtime information.
    ///
    /// - Parameters:
    ///   - userID: The local RTC account.
    ///   - taskID: The generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve input aspect ratio within the canvas.
    ///
    /// - Returns: The JSON condition update.
    ///
    /// - Throws: An error if parameters are invalid or JSON encoding fails.
    static func changeCondition(
        userID: String,
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) throws -> String {
        try encode(
            ChangeConditionPayload(
                params: GenerationParameters(
                    videoFormat: videoFormat,
                    targetSize: targetSize,
                    context: context,
                    faceRestoration: faceRestoration,
                    paddingContain: paddingContain
                ),
                userID: userID,
                taskID: taskID
            )
        )
    }

    /// Encodes a target-size and downlink bitrate update.
    ///
    /// - Parameters:
    ///   - userID: The local RTC account.
    ///   - taskID: The generation task to update.
    ///   - targetSize: The integer returned pixel dimensions.
    ///
    /// - Returns: The JSON target-size update.
    ///
    /// - Throws: An error if dimensions are invalid or bitrate resolution or JSON encoding fails.
    static func changeTargetSize(
        userID: String,
        taskID: String,
        targetSize: CGSize
    ) throws -> String {
        try encode(
            ChangeTargetSizePayload(
                params: TargetSizeParameters(size: targetSize),
                userID: userID,
                taskID: taskID
            )
        )
    }

    /// Encodes a generation stop signal.
    ///
    /// - Parameters:
    ///   - userID: The local RTC account.
    ///   - taskID: The generation task to stop.
    ///
    /// - Returns: The JSON stop message.
    ///
    /// - Throws: An error if JSON encoding fails.
    static func stop(
        userID: String,
        taskID: String
    ) throws -> String {
        try encode(
            StopPayload(
                userID: userID,
                taskID: taskID
            )
        )
    }

    /// Encodes a normalized media trajectory.
    ///
    /// - Parameters:
    ///   - userID: The local RTC account.
    ///   - taskID: The generation task receiving the trajectory.
    ///   - points: The ordered points in `[0, 1]`, relative to resolved media dimensions.
    ///
    /// - Returns: The JSON trajectory message.
    ///
    /// - Throws: An error if coordinates are invalid or JSON encoding fails.
    static func tracks(
        userID: String,
        taskID: String,
        points: [RealtimePoint]
    ) throws -> String {
        try encode(
            TracksPayload(
                tracks: points.map {
                    [$0.x, $0.y]
                },
                userID: userID,
                taskID: taskID
            )
        )
    }

    /// Encodes a room heartbeat.
    ///
    /// - Parameter userID: The local RTC account.
    ///
    /// - Returns: The JSON heartbeat message.
    ///
    /// - Throws: An error if JSON encoding fails.
    static func heartbeat(
        userID: String
    ) throws -> String {
        try encode(HeartbeatPayload(userID: userID))
    }
}

private extension RoomEvent {

    /// Validates returned dimensions and resolves the downlink bitrate budget.
    ///
    /// - Parameter size: The integer returned video dimensions.
    ///
    /// - Returns: The minimum and maximum downlink bitrate, in kbps.
    ///
    /// - Throws: An error if dimensions are invalid or bitrate resolution fails.
    static func downlinkBitrates(
        _ size: CGSize
    ) throws -> (minimum: Int, maximum: Int) {
        guard size.width.isFinite, size.height.isFinite,
            size.width >= 2, size.height >= 2,
            size.width < CGFloat(Int.max), size.height < CGFloat(Int.max),
            size.width.rounded(.down) == size.width,
            size.height.rounded(.down) == size.height
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Invalid return video dimensions"
            )
        }

        let budget = try EncodingBitratePolicy.resolve(
            RealtimeVideoFormat(
                width: Int(size.width),
                height: Int(size.height),
                fps: 24
            )
        )
        return (
            500,
            min(
                10000,
                max(500, budget.maximum)
            )
        )
    }

    /// Encodes signaling with shared runtime and task fields.
    ///
    /// - Parameter payload: The encodable event payload.
    ///
    /// - Returns: UTF-8 JSON with stable key ordering.
    ///
    /// - Throws: An error if payload encoding, JSON conversion, or text conversion fails.
    static func encode(
        _ payload: some Encodable
    ) throws -> String {
        let payloadData = try JSONEncoder().encode(
            Envelope(
                payload: payload,
                runtime: .current
            )
        )
        guard var object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            throw XmaxError(
                code: .internalError,
                message: "Failed to encode RTC room event"
            )
        }

        if let taskID = object["uid"] {
            object["session_uid"] = taskID
        }

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard
            let message = String(
                data: data,
                encoding: .utf8
            )
        else {
            throw XmaxError(
                code: .internalError,
                message: "Failed to encode RTC room event"
            )
        }

        return message
    }

    /// A signaling payload with runtime information.
    struct Envelope<Payload: Encodable>: Encodable {

        /// The business event payload.
        let payload: Payload

        /// The client runtime information sent with signaling.
        let runtime: RuntimeInfo

        /// Encodes the event and runtime in one container.
        ///
        /// - Parameter encoder: The signaling encoder.
        ///
        /// - Throws: An error if payload or runtime encoding fails.
        func encode(
            to encoder: Encoder
        ) throws {
            try payload.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                runtime,
                forKey: .runtime
            )
        }

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The client runtime field.
            case runtime
        }
    }

    /// The generation canvas, reference conditions, and output options.
    struct GenerationParameters: Encodable {

        /// The signaling model placeholder; the session determines the actual model.
        let model = "default"

        /// The generation canvas dimensions, in pixels.
        let size: [Int]

        /// The returned output dimensions, in pixels.
        let targetSize: [Int]?

        /// The generation prompt.
        let prompt: String

        /// The server-accessible reference image URL.
        let referencePath: String?

        /// Whether to mirror the input.
        let mirror: Bool?

        /// Whether face restoration is enabled.
        let faceRestoration: Bool

        /// The input-to-canvas padding policy.
        let padding: String?

        /// The server encoder minimum bitrate, in kbps.
        let minimumBitrate: Int?

        /// The server encoder maximum bitrate, in kbps.
        let maximumBitrate: Int?

        /// Creates generation parameters with optional downlink bitrate settings.
        ///
        /// - Parameters:
        ///   - videoFormat: The server generation format.
        ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
        ///   - context: The reference image and prompt conditions.
        ///   - faceRestoration: Whether to restore the original face.
        ///   - paddingContain: Whether to contain input within the canvas.
        ///   - mirror: The optional mirror setting. When provided, downlink bitrate fields are
        ///     included.
        ///
        /// - Throws: An error if dimensions or bitrate are invalid when a downlink budget is
        ///   required.
        init(
            videoFormat: RealtimeVideoFormat,
            targetSize: CGSize?,
            context: RealtimeContext,
            faceRestoration: Bool,
            paddingContain: Bool = false,
            mirror: Bool? = nil
        ) throws {
            size = [videoFormat.width, videoFormat.height]
            self.targetSize = targetSize.map {
                [Int($0.width), Int($0.height)]
            }
            prompt = context.prompt
            referencePath = context.referencePath
            self.mirror = mirror
            self.faceRestoration = faceRestoration
            padding = paddingContain ? "contain" : nil

            if mirror != nil {
                let budget = try RoomEvent.downlinkBitrates(targetSize ?? videoFormat.size)
                minimumBitrate = budget.minimum
                maximumBitrate = budget.maximum
            } else {
                minimumBitrate = nil
                maximumBitrate = nil
            }
        }

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The generation model field.
            case model

            /// The generation canvas field.
            case size

            /// The returned dimensions field.
            case targetSize = "target_size"

            /// The generation prompt field.
            case prompt

            /// The reference image field.
            case referencePath = "ref_image_path"

            /// The input mirroring field.
            case mirror

            /// The face restoration field.
            case faceRestoration = "face_replace"

            /// The canvas padding field.
            case padding

            /// The minimum bitrate field.
            case minimumBitrate = "min_bitrate"

            /// The maximum bitrate field.
            case maximumBitrate = "max_bitrate"
        }
    }

    /// A generation start room message.
    struct StartPayload: Encodable {

        /// The start event name.
        let event = "start"

        /// The generation dimensions, conditions, and display settings.
        let params: GenerationParameters

        /// The business user starting generation.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The event parameters field.
            case params

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A generation condition update room message.
    struct ChangeConditionPayload: Encodable {

        /// The condition update event name.
        let event = "change_condition"

        /// The updated generation and display conditions.
        let params: GenerationParameters

        /// The task's business user identifier.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The event parameters field.
            case params

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// The returned dimensions and downlink bitrate budget.
    struct TargetSizeParameters: Encodable {

        /// The returned output dimensions, in pixels.
        let targetSize: [Int]

        /// The server encoder minimum bitrate, in kbps.
        let minimumBitrate: Int

        /// The server encoder maximum bitrate, in kbps.
        let maximumBitrate: Int

        /// Creates validated target-size and bitrate parameters.
        ///
        /// - Parameter size: The integer target output dimensions.
        ///
        /// - Throws: An error if dimensions or downlink bitrate resolution fails.
        init(
            size: CGSize
        ) throws {
            let budget = try RoomEvent.downlinkBitrates(size)
            targetSize = [Int(size.width), Int(size.height)]
            minimumBitrate = budget.minimum
            maximumBitrate = budget.maximum
        }

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The returned dimensions field.
            case targetSize = "target_size"

            /// The minimum bitrate field.
            case minimumBitrate = "min_bitrate"

            /// The maximum bitrate field.
            case maximumBitrate = "max_bitrate"
        }
    }

    /// A dynamic target-size room message.
    struct ChangeTargetSizePayload: Encodable {

        /// The target-size event name.
        let event = "change_target_size"

        /// The new output dimensions and bitrate bounds.
        let params: TargetSizeParameters

        /// The task's business user identifier.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The event parameters field.
            case params

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A generation stop room message.
    struct StopPayload: Encodable {

        /// The stop event name.
        let event = "stop"

        /// The task's business user identifier.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A normalized media trajectory room message.
    struct TracksPayload: Encodable {

        /// The trajectory event name.
        let event = "tracks"

        /// The normalized points relative to complete resolved media dimensions, each as `[x, y]`.
        let tracks: [[Double]]

        /// The business user sending the trajectory.
        let userID: String

        /// The trajectory's generation task identifier.
        let taskID: String

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The normalized trajectory field.
            case tracks

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A room keepalive message.
    struct HeartbeatPayload: Encodable {

        /// The room heartbeat event name.
        let event = "heartbeat"

        /// The business user sending the heartbeat.
        let userID: String

        /// The server signaling field names.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The business user field.
            case userID = "user_id"
        }
    }
}
