//
//  RoomControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

/// An interface for room lifecycle and signaling.
protocol RoomControlling: Actor {

    /// Registers a listener for decoded messages in the current room.
    func setRoomMessageListener(_ listener: RealtimeRoomMessageListener?)

    /// Joins a realtime room while checking operation validity.
    ///
    /// - Parameters:
    ///   - connection: The server-assigned RTC credentials.
    ///   - ensureActive: The connection validity check.
    ///
    /// - Throws: An error if state is invalid, room join fails or times out, or the call is
    ///   cancelled.
    func join(
        connection: RealtimeSessionConnection,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws

    /// Cancels command retries before task media cleanup.
    func cancelGenerationCommands(taskID: String) async

    /// Stops the heartbeat and leaves the RTC room.
    func leave() async

    /// Enqueues a generation start signal.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve input aspect ratio within the canvas.
    ///
    /// - Throws: An error if the room is not ready or signaling encoding or enqueueing fails.
    func startGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) async throws

    /// Enqueues a generation condition update.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve input aspect ratio within the canvas.
    ///
    /// - Throws: An error if the room is not ready, the call is cancelled, or encoding or
    ///   enqueueing fails.
    func changeGenerationCondition(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) async throws

    /// Changes the active generation task's returned dimensions.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier.
    ///   - targetSize: The integer returned pixel dimensions.
    ///   - ensureActive: The configuration validity check before sending.
    ///
    /// - Throws: An error if cancelled, the room is not ready, or signaling fails.
    func changeTargetSize(
        taskID: String,
        targetSize: CGSize,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws

    /// Sends a stop signal if the room and task are active.
    ///
    /// - Parameter taskID: The generation task to stop.
    ///
    /// - Throws: An error if stop signaling cannot be encoded, enqueued, or sent.
    func stopGeneration(
        taskID: String
    ) async throws

    /// Submits a generation task's trajectory.
    ///
    /// - Parameters:
    ///   - taskID: The receiving task identifier. Empty identifiers are ignored.
    ///   - points: The normalized media points in `[0, 1]`. Empty arrays are ignored.
    ///
    /// - Throws: An error if the room is not ready or trajectory encoding or enqueueing fails.
    func sendTracks(
        taskID: String,
        points: [RealtimePoint]
    ) throws
}
