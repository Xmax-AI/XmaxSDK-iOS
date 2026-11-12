//
//  StreamController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A main-actor remote stream binding handler; `nil` clears the binding.
typealias RemoteStreamListener =
    @MainActor @Sendable (
        RemoteStream?
    ) throws -> Void

/// Coordinates RTC rooms, media streams, encoding, and quality.
final class StreamController: StreamControlling, RtcEventListener,
    @unchecked Sendable
{

    // MARK: - Dependencies

    /// The RTC media publication, subscription, and frame adapter.
    private let rtcManager: any RtcManaging

    /// The room connection and signaling controller.
    private let roomController: any RoomControlling

    /// The uplink encoder configuration controller.
    private let encodingController: any EncodingControlling

    /// The quality statistics and adaptation controller.
    private let qualityController: any QualityControlling

    /// The connection and generation startup timing recorder.
    private let timing: RealtimeTiming

    /// The transport failure handler.
    private let errorListener: XmaxErrorListener

    /// The remote result publication and end handler.
    private let remoteStreamListener: RemoteStreamListener

    /// The generation stream confirmation timeout.
    private let generationTiming: StreamGenerationTiming

    // MARK: - State

    /// The remote volume percentage, from 0 to 100.
    private var remoteAudioVolumePercentage = 100

    /// The lock protecting connection, media, and generation state.
    private let stateLock = NSLock()

    /// The lock serializing media and generation operations.
    private let operationLock = NSRecursiveLock()

    /// The transport state snapshot.
    private var state = State()

    /// Whether a generation task remains active.
    var hasGenerationTask: Bool {
        stateLock.withLock {
            state.generationTask != nil
        }
    }

    var lastStoppedTaskID: String? {
        stateLock.withLock { state.lastStoppedTaskID }
    }

    func setRoomMessageListener(_ listener: RealtimeRoomMessageListener?) async {
        await roomController.setRoomMessageListener(listener)
    }

    /// The remote playback volume, from 0 to 1.
    var remoteAudioVolume: Float {
        Float(
            stateLock.withLock {
                remoteAudioVolumePercentage
            }
        ) / 100
    }

    /// Creates a stream controller with room, encoding, and quality components.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC manager.
    ///   - timing: The shared startup timing recorder.
    ///   - errorListener: The stream failure handler.
    ///   - remoteStreamListener: The remote result binding handler.
    ///   - generationTiming: The result stream confirmation timeout.
    convenience init(
        rtcManager: any RtcManaging,
        timing: RealtimeTiming = RealtimeTiming(),
        errorListener: @escaping XmaxErrorListener = { _ in
        },
        remoteStreamListener: @escaping RemoteStreamListener = { _ in
        },
        generationTiming: StreamGenerationTiming = .live
    ) {
        self.init(
            rtcManager: rtcManager,
            roomController: RoomController(
                rtcManager: rtcManager,
                timing: timing
            ),
            encodingController: EncodingController(rtcManager: rtcManager),
            qualityController: QualityController(rtcManager: rtcManager),
            timing: timing,
            errorListener: errorListener,
            remoteStreamListener: remoteStreamListener,
            generationTiming: generationTiming
        )
    }

    /// Creates a stream controller with the specified components.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC manager.
    ///   - roomController: The room connection and signaling component.
    ///   - encodingController: The video encoder component.
    ///   - qualityController: The quality and adaptation component.
    ///   - timing: The shared startup timing recorder.
    ///   - errorListener: The stream failure handler.
    ///   - remoteStreamListener: The remote result binding handler.
    ///   - generationTiming: The result stream confirmation timeout.
    init(
        rtcManager: any RtcManaging,
        roomController: any RoomControlling,
        encodingController: any EncodingControlling,
        qualityController: any QualityControlling,
        timing: RealtimeTiming = RealtimeTiming(),
        errorListener: @escaping XmaxErrorListener = { _ in
        },
        remoteStreamListener: @escaping RemoteStreamListener = { _ in
        },
        generationTiming: StreamGenerationTiming = .live
    ) {
        self.rtcManager = rtcManager
        self.roomController = roomController
        self.encodingController = encodingController
        self.qualityController = qualityController
        self.timing = timing
        self.errorListener = errorListener
        self.remoteStreamListener = remoteStreamListener
        self.generationTiming = generationTiming
        rtcManager.setEventListener(self)
    }

    /// Sets the realtime video encoder configuration.
    ///
    /// - Parameter videoFormat: The RTC encoding dimensions and frame rate.
    ///
    /// - Throws: An error if the format is invalid or RTC configuration fails.
    func setVideoEncoderConfig(
        _ videoFormat: RealtimeVideoFormat
    ) throws {
        try encodingController.configure(videoFormat)
    }

    /// The current media baseline and directional quality levels.
    var qualityConfiguration: QualityConfiguration? {
        qualityController.qualityConfiguration
    }

    /// Prepares quality levels from the media baseline and model history.
    ///
    /// - Parameters:
    ///   - baseline: The resolved local media baseline, unchanged by adaptation.
    ///   - model: The model identifier isolating quality history.
    ///   - minimumInputPixels: The model's minimum uplink area, in pixels.
    ///   - isAdaptiveQualityEnabled: Whether to adapt quality. Disabled connections start at L1
    ///     without using history.
    ///
    /// - Returns: The initial directional quality configuration.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        model: String,
        minimumInputPixels: Int,
        isAdaptiveQualityEnabled: Bool
    ) -> QualityConfiguration {
        qualityController.prepareQuality(
            baseline: baseline,
            model: model,
            minimumInputPixels: minimumInputPixels,
            isAdaptiveQualityEnabled: isAdaptiveQualityEnabled
        )
    }

    /// Sets internal quality sampling independently of the public network listener.
    ///
    /// - Parameter listener: The quality and monotonic sample time handler, or `nil` to remove it.
    func setAdaptiveQualityListener(
        _ listener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?
    ) {
        qualityController.setAdaptiveQualityListener(listener)
    }

    /// Proposes levels from the current network sample.
    ///
    /// - Parameters:
    ///   - quality: The current directional network quality.
    ///   - sampledAt: The monotonic sample time, in seconds.
    ///
    /// - Returns: The candidate levels satisfying sample and cooldown requirements.
    func proposeQuality(
        _ quality: RealtimeNetworkQuality,
        sampledAt: TimeInterval
    ) -> QualityChange {
        qualityController.proposeQuality(
            quality,
            sampledAt: sampledAt
        )
    }

    /// Commits adjustment results, persisting successful levels.
    ///
    /// - Parameters:
    ///   - downlink: Whether this is downlink rather than uplink.
    ///   - level: The attempted quality level.
    ///   - success: Whether configuration succeeded.
    func completeQuality(
        downlink: Bool,
        level: RealtimeQualityLevel,
        success: Bool
    ) {
        qualityController.completeQuality(
            downlink: downlink,
            level: level,
            success: success
        )
    }

    /// Clears consecutive quality samples.
    func resetQualitySamples() {
        qualityController.resetQualitySamples()
    }

    /// Sets the uplink video statistics listener.
    ///
    /// - Parameter listener: The main-actor handler, receiving `nil` when unpublished or
    ///   disconnected. Pass `nil` to remove it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) {
        qualityController.setUplinkVideoStatisticsListener(listener)
    }

    /// Sets the downlink video statistics listener.
    ///
    /// - Parameter listener: The main-actor handler, receiving `nil` when the result stream clears.
    ///   Pass `nil` to remove it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) {
        qualityController.setDownlinkVideoStatisticsListener(listener)
    }

    /// Sets the network quality listener.
    ///
    /// - Parameter listener: The directional network quality listener;
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) {
        qualityController.setNetworkQualityListener(listener)
    }

    /// Sets the device performance listener.
    ///
    /// - Parameter listener: The device limitation and recovery listener;
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) {
        qualityController.setPerformanceAlarmListener(listener)
    }

    /// Sets remote generated audio volume.
    ///
    /// - Parameter volume: The validated volume, in the range `0...1`.
    ///
    /// - Throws: An error if RTC volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Float
    ) throws {
        let rtcVolume = Int((volume * 100).rounded())
        try operationLock.withLock {
            let userIDs = stateLock.withLock {
                state.subscribedRemoteAudioUserIDs.sorted()
            }

            for userID in userIDs {
                try rtcManager.setRemoteAudioVolume(
                    rtcVolume,
                    for: userID
                )
            }

            stateLock.withLock {
                remoteAudioVolumePercentage = rtcVolume
            }
        }
    }

    /// Joins an RTC room and publishes local media.
    ///
    /// - Parameters:
    ///   - connection: The RTC room, user, token, and result user information.
    ///   - includeLocalAudio: Whether to publish audio alongside local video.
    ///   - ensureActive: The connection validity check across asynchronous boundaries;
    ///
    /// - Throws: An error if cancelled or RTC join, configuration, or local publication fails.
    func connect(
        connection: RealtimeSessionConnection,
        includeLocalAudio: Bool,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws {
        try ensureActive()
        try configureRoom(
            roomID: connection.roomID,
            botName: connection.botName
        )
        try await roomController.join(
            connection: connection,
            ensureActive: ensureActive
        )
        try ensureActive()
        timing.beginLocalPublication()
        try publishLocalStream(includeAudio: includeLocalAudio)
        timing.finishLocalPublication()
    }

    /// Disconnects the RTC room and releases media and generation state; safe when no room is
    /// active.
    func disconnect() async {
        qualityController.resetQuality()
        await resetStream()
        await roomController.leave()
    }

    /// Starts a generation task and its result stream confirmation.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation prompt and reference conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to contain input within the generation canvas.
    ///
    /// - Returns: The task awaiting remote result stream confirmation.
    ///
    /// - Throws: An error if the task or room is invalid, a task exists, or signaling fails or
    ///   times out.
    func beginGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) async throws -> Task<Void, any Error> {
        timing.beginSignal(taskID: taskID)
        let confirmation = try beginGenerationConfirmation(taskID: taskID)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.roomController.startGeneration(
                        taskID: taskID,
                        videoFormat: videoFormat,
                        targetSize: targetSize,
                        context: context,
                        faceRestoration: faceRestoration,
                        paddingContain: paddingContain
                    )
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: self.generationTiming.timeoutNanoseconds)
                    throw XmaxError(
                        code: .timeout,
                        message: "Realtime generation start timed out"
                    )
                }
                defer {
                    group.cancelAll()
                }

                try await group.next()
            }

            try Task.checkCancellation()
            await confirmPublishedRemoteStream(taskID: taskID)
            return confirmation
        } catch {
            confirmation.cancel()
            try? await stopGeneration(taskID: taskID)
            throw XmaxError.from(error)
        }
    }

    /// Subscribes to generated audio after remote video is ready.
    ///
    /// - Throws: An error if the result stream is unconfirmed or RTC volume or subscription fails.
    func activateRemoteAudio() throws {
        try operationLock.withLock {
            let remoteStream: RemoteStream? = stateLock.withLock {
                guard state.generationTask != nil else {
                    return nil
                }
                return state.activeRemoteStream
            }
            guard let remoteStream else {
                throw XmaxError(
                    code: .rtcError,
                    message: "Remote generation audio stream is unavailable"
                )
            }

            try subscribeRemoteAudio(userID: remoteStream.userID)
        }
    }

    /// Sends an active task's condition update.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation format.
    ///   - targetSize: The returned dimensions, or `nil` to retain generation dimensions.
    ///   - context: The generation prompt and reference conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to contain input within the generation canvas.
    ///
    /// - Throws: An error if the room or parameters are invalid or signaling submission fails.
    func updateGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) async throws {
        try await roomController.changeGenerationCondition(
            taskID: taskID,
            videoFormat: videoFormat,
            targetSize: targetSize,
            context: context,
            faceRestoration: faceRestoration,
            paddingContain: paddingContain
        )
    }

    /// Stops generation and clears its result stream.
    ///
    /// - Parameter taskID: The task to stop. An empty string stops
    ///
    /// - Throws: An error if the RTC stop signal cannot be sent.
    func stopGeneration(
        taskID: String
    ) async throws {
        guard let stopped = await clearGeneration(taskID: taskID) else {
            return
        }
        try await roomController.stopGeneration(
            taskID: stopped.taskID,
            confirmationSender: stopped.resultUserID
        )
        if let error = stopped.videoSuspensionError {
            throw error
        }
    }

    /// Sends a generation task's trajectory.
    ///
    /// - Parameters:
    ///   - taskID: The task receiving the trajectory.
    ///   - points: The trajectory points. Empty arrays are ignored.
    ///
    /// - Throws: An error if the room or task is invalid or trajectory signaling fails.
    func sendTracks(
        taskID: String,
        points: [RealtimePoint]
    ) async throws {
        try await roomController.sendTracks(
            taskID: taskID,
            points: points
        )
    }

    /// Sets the room and expected result user.
    ///
    /// - Parameters:
    ///   - roomID: The RTC room identifier.
    ///   - botName: The expected result account, or `nil` or empty to allow any account.
    ///
    /// - Throws: An error if the room identifier is empty or media remains active.
    func configureRoom(
        roomID: String,
        botName: String?
    ) throws {
        let roomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let botName =
            botName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !roomID.isEmpty else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC room ID cannot be empty"
            )
        }

        try operationLock.withLock {
            try stateLock.withLock {
                guard !state.localVideoPublished,
                    !state.localAudioPublished,
                    state.subscribedRemoteUserIDs.isEmpty,
                    state.generationTask == nil
                else {
                    throw XmaxError(
                        code: .invalidConfiguration,
                        message: "Reset the current RTC room before configuring another one"
                    )
                }

                state.roomID = roomID
                state.botName = botName
            }
        }
    }

    /// Publishes local video and optional audio.
    ///
    /// - Parameter includeAudio: Whether to also publish local audio.
    ///
    /// - Throws: An error if the room is unconfigured or RTC publication fails.
    func publishLocalStream(
        includeAudio: Bool
    ) throws {
        try operationLock.withLock {
            let currentState = stateLock.withLock {
                state
            }
            guard !currentState.roomID.isEmpty else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Configure an RTC room before publishing the local stream"
                )
            }

            var publishedVideoInOperation = false

            do {
                if !currentState.localVideoPublished {
                    try rtcManager.publishLocalVideo()
                    stateLock.withLock {
                        state.localVideoPublished = true
                    }
                    qualityController.setUplinkVideoStatisticsEnabled(true)
                    publishedVideoInOperation = true
                }

                if includeAudio && !currentState.localAudioPublished {
                    try rtcManager.publishLocalAudio()
                    stateLock.withLock {
                        state.localAudioPublished = true
                    }
                }
            } catch {
                if publishedVideoInOperation {
                    rollbackLocalVideoPublication()
                }
                throw XmaxError.from(error)
            }
        }
    }

    /// Unpublishes the input while keeping the RTC room open.
    func unpublishLocalStream() throws {
        try operationLock.withLock {
            let publication = stateLock.withLock {
                (video: state.localVideoPublished, audio: state.localAudioPublished)
            }
            let video = Result {
                if publication.video {
                    try rtcManager.unpublishLocalVideo()
                    stateLock.withLock { state.localVideoPublished = false }
                    qualityController.setUplinkVideoStatisticsEnabled(false)
                }
            }
            if publication.audio {
                try rtcManager.unpublishLocalAudio()
                stateLock.withLock { state.localAudioPublished = false }
            }
            try video.get()
        }
    }

    /// Pushes external video during generation, ignoring frames without an active task.
    ///
    /// - Parameter frame: The local frame prepared for RTC.
    ///
    /// - Throws: An error if RTC is unready or video conversion fails.
    func pushLocalVideoFrame(
        _ frame: VideoFrame
    ) throws {
        try operationLock.withLock {
            guard stateLock.withLock({ state.generationTask != nil && state.localVideoPublished }) else {
                return
            }
            do {
                try rtcManager.pushExternalVideoFrame(frame)
            } catch {
                throw XmaxError.from(error)
            }
        }
    }

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: The PCM frame prepared for RTC;
    ///
    /// - Throws: An error if RTC is unready or audio conversion fails.
    func pushLocalAudioFrame(
        _ frame: AudioFrame
    ) throws {
        guard
            stateLock.withLock({
                state.localAudioPublished
            })
        else {
            return
        }

        do {
            try rtcManager.pushExternalAudioFrame(frame)
        } catch {
            throw XmaxError.from(error)
        }
    }

    /// Changes returned dimensions without restarting generation.
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
    ) async throws {
        try await roomController.changeTargetSize(
            taskID: taskID,
            targetSize: targetSize,
            ensureActive: ensureActive
        )
    }

    /// Creates a generation result stream wait.
    ///
    /// - Parameter taskID: The generation task to confirm.
    ///
    /// - Returns: The cancellable confirmation task.
    ///
    /// - Throws: An error if the task or room is invalid, a task exists, or a waiter cannot be
    ///   created.
    func beginGenerationConfirmation(
        taskID: String
    ) throws -> Task<Void, any Error> {
        let taskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Realtime generation task ID cannot be empty"
            )
        }

        return try operationLock.withLock {
            let currentState = stateLock.withLock {
                state
            }
            guard !currentState.roomID.isEmpty else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC room is not configured"
                )
            }
            guard currentState.generationTask == nil else {
                throw XmaxError(
                    code: .rtcError,
                    message: "Realtime generation is already active"
                )
            }
            try suspendRemoteVideoSubscriptions()

            var continuation: AsyncThrowingStream<Void, any Error>.Continuation?
            let stream = AsyncThrowingStream<Void, any Error> {
                continuation = $0
            }
            guard let continuation else {
                throw XmaxError(
                    code: .internalError,
                    message: "Failed to create generation confirmation"
                )
            }

            let waiter = GenerationWaiter(
                taskID: taskID,
                continuation: continuation
            )
            stateLock.withLock {
                state.generationTask = GenerationTask(id: taskID)
                state.generationWaiter = waiter
                state.lastStoppedTaskID = nil
            }

            waiter.timeoutTask = Task { [weak self, weak waiter] in
                guard let self, let waiter else {
                    return
                }

                do {
                    try await Task.sleep(
                        nanoseconds: self.generationTiming.timeoutNanoseconds
                    )
                } catch {
                    return
                }

                self.rejectGenerationStart(
                    taskID: waiter.taskID,
                    error: XmaxError(
                        code: .timeout,
                        message: "Realtime generation start timed out"
                    )
                )
            }

            return Task { [weak self] in
                try await withTaskCancellationHandler {
                    for try await _ in stream {
                        return
                    }
                } onCancel: {
                    self?.rejectGenerationStart(
                        taskID: taskID,
                        error: XmaxError(
                            code: .cancelled,
                            message: "Realtime generation start cancelled"
                        )
                    )
                }
            }
        }
    }

    /// Stops a matching task and clears its audio and result binding.
    ///
    /// - Parameters:
    ///   - taskID: The task identifier, or an empty string for the current task.
    ///   - reason: The reason for cancelling confirmation.
    ///
    /// - Returns: The stopped task identifier, or empty if none matched.
    @discardableResult
    func stopStreamGeneration(
        taskID: String,
        reason: String = "Realtime generation start cancelled"
    ) async -> String {
        await clearGeneration(taskID: taskID, reason: reason)?.taskID ?? ""
    }

    /// Invalidates the task and suspends its result video until the next start is sent.
    private func clearGeneration(
        taskID: String,
        reason: String = "Realtime generation start cancelled"
    ) async -> StopResult? {
        let result = operationLock.withLock { () -> StopResult? in
            let currentTaskID = stateLock.withLock {
                state.generationTask?.id ?? ""
            }
            guard taskID.isEmpty || taskID == currentTaskID else {
                return nil
            }

            let stoppedState = stateLock.withLock { () -> (
                waiter: GenerationWaiter?, audioUsers: Set<String>, resultUser: String?
            ) in
                let waiter = state.generationWaiter
                let remoteAudioUserIDs = state.subscribedRemoteAudioUserIDs
                let resultUserID = state.generationTask?.resultUserID
                if !currentTaskID.isEmpty {
                    state.lastStoppedTaskID = currentTaskID
                }
                if resultUserID != nil {
                    state.remoteVideoSuspended = true
                }
                state.generationTask = nil
                state.generationWaiter = nil
                state.activeRemoteStream = nil
                state.subscribedRemoteAudioUserIDs.removeAll()
                return (waiter, remoteAudioUserIDs, resultUserID)
            }

            let videoSuspensionError: XmaxError?
            do {
                try suspendRemoteVideoSubscriptions()
                videoSuspensionError = nil
            } catch {
                videoSuspensionError = XmaxError.from(error)
            }
            return StopResult(
                taskID: currentTaskID,
                waiter: stoppedState.waiter,
                remoteAudioUserIDs: stoppedState.audioUsers,
                resultUserID: stoppedState.resultUser,
                videoSuspensionError: videoSuspensionError
            )
        }
        guard let result else {
            return nil
        }

        await roomController.cancelGenerationCommands(taskID: result.taskID)

        reject(
            result.waiter,
            error: XmaxError(
                code: .cancelled,
                message: reason
            )
        )

        for userID in result.remoteAudioUserIDs.sorted() {
            performCleanup(
                "取消订阅 RTC 远端音频失败 (Failed to Unsubscribe from RTC Remote Audio)"
            ) {
                try rtcManager.subscribeRemoteAudio(
                    userID: userID,
                    subscribe: false
                )
            }
        }

        await clearRemoteStream()
        return result
    }

    /// Releases generation, publication, and subscription resources.
    func resetStream() async {
        qualityController.setUplinkVideoStatisticsEnabled(false)
        _ = await stopStreamGeneration(taskID: "")

        operationLock.withLock {
            let previousState = stateLock.withLock { () -> State in
                let previousState = state
                state = State()
                return previousState
            }

            for userID in previousState.subscribedRemoteUserIDs.sorted() {
                performCleanup(
                    "取消订阅 RTC 远端视频失败 (Failed to Unsubscribe from RTC Remote Video)"
                ) {
                    try rtcManager.subscribeRemoteVideo(
                        userID: userID,
                        subscribe: false
                    )
                }
            }

            if previousState.localAudioPublished {
                performCleanup(
                    "取消发布 RTC 本地音频失败 (Failed to Unpublish RTC Local Audio)"
                ) {
                    try rtcManager.unpublishLocalAudio()
                }
            }

            if previousState.localVideoPublished {
                performCleanup(
                    "取消发布 RTC 本地视频失败 (Failed to Unpublish RTC Local Video)"
                ) {
                    try rtcManager.unpublishLocalVideo()
                }
            }
        }
    }

    /// Reports remote video publication changes.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - published: Whether video is currently published.
    @MainActor
    func onRemoteVideoPublished(
        userID: String,
        published: Bool
    ) {
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else {
            return
        }

        operationLock.withLock {
            let currentState = stateLock.withLock {
                state
            }
            guard !currentState.roomID.isEmpty,
                currentState.botName.isEmpty || currentState.botName == userID
            else {
                return
            }

            if published {
                _ = stateLock.withLock { state.publishedRemoteUserIDs.insert(userID) }
                guard !currentState.remoteVideoSuspended else {
                    return
                }
                subscribeRemoteVideo(userID: userID)
                confirmRemoteStream(
                    RemoteStream(
                        roomID: currentState.roomID,
                        userID: userID
                    )
                )
            } else {
                stateLock.withLock {
                    state.publishedRemoteUserIDs.remove(userID)
                    state.subscribedRemoteUserIDs.remove(userID)
                }
                if currentState.activeRemoteStream?.userID == userID {
                    unsubscribeRemoteAudio(userID: userID)
                    stateLock.withLock {
                        state.activeRemoteStream = nil
                    }
                    clearRemoteStream()
                }
            }
        }
    }

    /// Reports a failure preventing further connection or signaling.
    ///
    /// - Parameter error: The connection or signaling failure.
    @MainActor
    func onRtcFailure(
        _ error: XmaxError
    ) {
        let taskID = stateLock.withLock {
            state.generationWaiter?.taskID
        }
        if let taskID {
            rejectGenerationStart(
                taskID: taskID,
                error: error
            )
        } else {
            errorListener(error)
        }
    }
}

private extension StreamController {

    /// Marks start signaling as sent and confirms an available result stream.
    ///
    /// - Parameter taskID: The task whose start signal was sent.
    @MainActor
    func confirmPublishedRemoteStream(
        taskID: String
    ) {
        operationLock.withLock {
            let stream = stateLock.withLock { () -> RemoteStream? in
                guard let waiter = state.generationWaiter, waiter.taskID == taskID else {
                    return nil
                }

                waiter.signalSent = true
                state.remoteVideoSuspended = false
                guard let userID = state.publishedRemoteUserIDs.first else {
                    return nil
                }
                return RemoteStream(
                    roomID: state.roomID,
                    userID: userID
                )
            }

            if let stream {
                subscribeRemoteVideo(userID: stream.userID)
                confirmRemoteStream(stream)
            }
        }
    }

    /// Binds a published result stream and completes confirmation.
    ///
    /// - Parameter stream: The remote result stream to confirm.
    @MainActor
    func confirmRemoteStream(
        _ stream: RemoteStream
    ) {
        let waiter = operationLock.withLock { () -> GenerationWaiter? in
            stateLock.withLock {
                guard state.generationTask != nil,
                    let waiter = state.generationWaiter,
                    waiter.signalSent,
                    !waiter.confirmationPending,
                    state.subscribedRemoteUserIDs.contains(stream.userID),
                    stream.roomID == state.roomID,
                    state.botName.isEmpty || stream.userID == state.botName
                else {
                    return nil
                }

                waiter.confirmationPending = true
                return waiter
            }
        }
        guard let waiter else {
            return
        }

        do {
            try remoteStreamListener(stream)
            stateLock.withLock {
                if state.generationTask?.id == waiter.taskID {
                    state.activeRemoteStream = stream
                    state.generationTask?.resultUserID = stream.userID
                    qualityController.setDownlinkVideoStatisticsUser(stream.userID)
                }
            }
        } catch {
            rejectGenerationStart(
                taskID: waiter.taskID,
                error: XmaxError.from(error)
            )
            return
        }

        resolveGenerationStart(taskID: waiter.taskID)
    }
}

private extension StreamController {

    /// The room's publication, subscription, and generation state.
    struct State {

        /// The current RTC room identifier.
        var roomID = ""

        /// The server-assigned result user identifier.
        var botName = ""

        /// Whether local video is published.
        var localVideoPublished = false

        /// Whether local audio is published.
        var localAudioPublished = false

        /// The remote users with subscribed video.
        var subscribedRemoteUserIDs: Set<String> = []

        /// Published users are retained even while the old subscription is paused.
        var publishedRemoteUserIDs: Set<String> = []

        /// Whether to keep remote video unsubscribed between tasks.
        var remoteVideoSuspended = false

        /// The remote users with subscribed audio.
        var subscribedRemoteAudioUserIDs: Set<String> = []

        /// The submitted generation task.
        var generationTask: GenerationTask?

        /// The last task removed from the current room, including interrupted startup.
        var lastStoppedTaskID: String?

        /// The waiter for generation signaling and remote stream readiness.
        var generationWaiter: GenerationWaiter?

        /// The confirmed remote result stream.
        var activeRemoteStream: RemoteStream?
    }

    /// The identity of an active generation task.
    struct GenerationTask {

        /// The unique generation task identifier.
        let id: String

        /// The RTC user that published this task's result video.
        var resultUserID: String?
    }

    /// A result stream waiter with timeout and asynchronous notification.
    final class GenerationWaiter: @unchecked Sendable {

        /// The generation task awaiting its result stream.
        let taskID: String

        /// The continuation completing confirmation.
        let continuation: AsyncThrowingStream<Void, any Error>.Continuation

        /// The generation result timeout task.
        var timeoutTask: Task<Void, Never>?

        /// Whether a matching result stream is being confirmed.
        var confirmationPending = false

        /// Whether start signaling was submitted successfully.
        var signalSent = false

        /// Creates a generation stream confirmation context.
        init(
            taskID: String,
            continuation:
                AsyncThrowingStream<Void, any Error>.Continuation
        ) {
            self.taskID = taskID
            self.continuation = continuation
        }
    }

    /// The waiter and audio subscriptions retained for stop cleanup.
    struct StopResult {

        /// The generation task to stop.
        let taskID: String

        /// The generation waiter to finish during cleanup.
        let waiter: GenerationWaiter?

        /// The remote audio subscriptions to cancel.
        let remoteAudioUserIDs: Set<String>

        /// The expected sender for the stopped task's confirmation.
        let resultUserID: String?

        /// An error pausing video, with unsuccessful subscriptions retained for retry.
        let videoSuspensionError: XmaxError?
    }

    /// Unsubscribes previous video while the operation lock excludes publication callbacks.
    func suspendRemoteVideoSubscriptions() throws {
        let users = stateLock.withLock {
            state.remoteVideoSuspended ? state.subscribedRemoteUserIDs : []
        }
        for userID in users.sorted() {
            try rtcManager.subscribeRemoteVideo(userID: userID, subscribe: false)
            _ = stateLock.withLock { state.subscribedRemoteUserIDs.remove(userID) }
        }
    }

    /// Subscribes to remote video and reports failure to startup or runtime handling.
    ///
    /// - Parameter userID: The remote user to subscribe to.
    func subscribeRemoteVideo(
        userID: String
    ) {
        let alreadySubscribed = stateLock.withLock {
            state.subscribedRemoteUserIDs.contains(userID)
        }
        guard !alreadySubscribed else {
            return
        }

        do {
            try rtcManager.subscribeRemoteVideo(
                userID: userID,
                subscribe: true
            )
            _ = stateLock.withLock {
                state.subscribedRemoteUserIDs.insert(userID)
            }
        } catch {
            let xmaxError = XmaxError.from(error)
            let pendingTaskID = stateLock.withLock {
                state.generationWaiter == nil
                    ? nil
                    : state.generationTask?.id
            }
            if let pendingTaskID {
                rejectGenerationStart(
                    taskID: pendingTaskID,
                    error: xmaxError
                )
            } else {
                errorListener(xmaxError)
            }
        }
    }

    /// Applies volume and subscribes to remote audio.
    ///
    /// - Parameter userID: The remote user to subscribe to.
    ///
    /// - Throws: An error if volume configuration or audio subscription fails.
    func subscribeRemoteAudio(
        userID: String
    ) throws {
        let audioState = stateLock.withLock {
            (
                state.subscribedRemoteAudioUserIDs.contains(userID),
                remoteAudioVolumePercentage
            )
        }
        guard !audioState.0 else {
            return
        }

        try rtcManager.setRemoteAudioVolume(
            audioState.1,
            for: userID
        )
        try rtcManager.subscribeRemoteAudio(
            userID: userID,
            subscribe: true
        )
        _ = stateLock.withLock {
            state.subscribedRemoteAudioUserIDs.insert(userID)
        }
    }

    /// Cancels a recorded remote audio subscription.
    ///
    /// - Parameter userID: The remote user to unsubscribe.
    func unsubscribeRemoteAudio(
        userID: String
    ) {
        let wasSubscribed = stateLock.withLock {
            state.subscribedRemoteAudioUserIDs.remove(userID) != nil
        }
        guard wasSubscribed else {
            return
        }

        performCleanup(
            "取消订阅 RTC 远端音频失败 (Failed to Unsubscribe from RTC Remote Audio)"
        ) {
            try rtcManager.subscribeRemoteAudio(
                userID: userID,
                subscribe: false
            )
        }
    }

    /// Completes confirmation for a matching generation task.
    ///
    /// - Parameter taskID: The confirmed generation task identifier.
    func resolveGenerationStart(
        taskID: String
    ) {
        let waiter = operationLock.withLock { () -> GenerationWaiter? in
            stateLock.withLock {
                guard state.generationTask?.id == taskID, state.generationWaiter?.taskID == taskID else {
                    return nil
                }
                let waiter = state.generationWaiter
                state.generationWaiter = nil
                return waiter
            }
        }
        guard let waiter else {
            return
        }

        waiter.timeoutTask?.cancel()
        waiter.continuation.yield()
        waiter.continuation.finish()
    }

    /// Fails confirmation for a matching generation task.
    ///
    /// - Parameters:
    ///   - taskID: The failed generation task identifier.
    ///   - error: The confirmation failure.
    func rejectGenerationStart(
        taskID: String,
        error: XmaxError
    ) {
        let waiter = operationLock.withLock { () -> GenerationWaiter? in
            stateLock.withLock {
                guard state.generationTask?.id == taskID, state.generationWaiter?.taskID == taskID else {
                    return nil
                }
                let waiter = state.generationWaiter
                state.generationWaiter = nil
                return waiter
            }
        }

        reject(
            waiter,
            error: error
        )
    }

    /// Fails a waiter and cancels its timeout.
    ///
    /// - Parameters:
    ///   - waiter: The waiter to finish, or `nil` for no operation.
    ///   - error: The error returned to the waiter.
    func reject(
        _ waiter: GenerationWaiter?,
        error: XmaxError
    ) {
        guard let waiter else {
            return
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.finish(throwing: error)
    }

    /// Clears downlink statistics and the remote result binding.
    @MainActor
    func clearRemoteStream() {
        qualityController.setDownlinkVideoStatisticsUser(nil)
        do {
            try remoteStreamListener(nil)
        } catch {
            XmaxLogger.stream.error(
                message: "清理 RTC 远端生成流失败 (Failed to Clean Up RTC Remote Generation Stream)\n"
                    + "└─ \(XmaxLogger.localized("原因：", "Reason: "))"
                    + (error as NSError).localizedDescription
            )
        }
    }

    /// Unpublishes this operation's video and clears uplink statistics.
    func rollbackLocalVideoPublication() {
        qualityController.setUplinkVideoStatisticsEnabled(false)

        do {
            try rtcManager.unpublishLocalVideo()
            stateLock.withLock {
                state.localVideoPublished = false
            }
        } catch {
            XmaxLogger.stream.error(
                message: "回滚 RTC 本地视频发布失败 (Failed to Roll Back RTC Local Video Publication)\n"
                    + "└─ \(XmaxLogger.localized("原因：", "Reason: "))"
                    + (error as NSError).localizedDescription
            )
        }
    }

    /// Performs cleanup while logging failures.
    ///
    /// - Parameters:
    ///   - title: The bilingual cleanup failure title.
    ///   - action: The synchronous cleanup operation.
    func performCleanup(
        _ title: String,
        action: () throws -> Void
    ) {
        do {
            try action()
        } catch {
            XmaxLogger.stream.error(
                message: "\(title)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))"
                    + (error as NSError).localizedDescription
            )
        }
    }
}

/// The generation confirmation timeout configuration.
struct StreamGenerationTiming: Sendable {

    /// The result stream confirmation timeout, in nanoseconds.
    let timeoutNanoseconds: UInt64

    /// The default result confirmation timeout.
    static let live = StreamGenerationTiming(
        timeoutNanoseconds: 30_000_000_000
    )
}
