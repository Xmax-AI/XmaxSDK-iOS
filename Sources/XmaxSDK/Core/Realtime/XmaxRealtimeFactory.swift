//
//  XmaxRealtimeFactory.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The shared components used by the public facade and its lifecycle manager.
struct XmaxRealtimeComponents: Sendable {

    /// The manager that coordinates operation admission and resource cleanup.
    let lifecycleManager: XmaxRealtimeLifecycleManager

    /// The manager that owns the server session and RTC connection.
    let connectionManager: XmaxRealtimeConnectionManager

    /// The manager that starts generation and updates conditions.
    let generationManager: XmaxRealtimeGenerationManager

    /// The manager that logs and routes runtime failures.
    let errorManager: XmaxRealtimeErrorManager

    /// The controller that owns local media and interactions.
    let mediaController: any MediaControlling

    /// The controller that owns remote rendering and processed output.
    let renderController: any RenderControlling

    /// The controller that manages RTC publishing and signaling.
    let streamController: any StreamControlling

    /// The service that resolves media dimensions and model constraints.
    let mediaService: any MediaServicing

    /// The recorder for generation startup durations.
    let timing: RealtimeTiming
}

/// Creates realtime components and wires their frame, failure, and cleanup callbacks.
enum XmaxRealtimeFactory {

    /// Creates the components for a realtime manager.
    ///
    /// - Parameters:
    ///   - options: The model, interpolation, and adaptive quality settings.
    ///   - apiService: The service used to create and maintain server sessions.
    ///
    /// - Returns: The configured components and their shared lifecycle manager.
    @MainActor
    static func make(
        options: RealtimeConfiguration,
        apiService: any ApiServicing
    ) -> XmaxRealtimeComponents {
        let errorManager = XmaxRealtimeErrorManager()
        let rtcManager = RtcManager(provider: options.rtcProvider)
        let mediaService = MediaService(model: options.model)
        let timing = RealtimeTiming()

        let renderController = RenderController(
            rtcManager: rtcManager,
            frameInterpolationEnabled: options.isFrameInterpolationEnabled,
            frameInterpolationSupportChecker: {
                mediaService.supportsFrameInterpolation(for: $0)
            },
            errorListener: {
                errorManager.forward(
                    $0,
                    target: .connection
                )
            }
        )

        let streamController = StreamController(
            rtcManager: rtcManager,
            rtcProvider: options.rtcProvider,
            timing: timing,
            errorListener: {
                errorManager.forward(
                    $0,
                    target: .connection
                )
            },
            remoteStreamListener: { stream in
                try renderController.setRemoteStream(stream)
            }
        )

        let mediaController = MediaController(
            rtcManager: rtcManager,
            mediaService: mediaService,
            videoFrameListener: { frame in
                try streamController.pushLocalVideoFrame(frame)
            },
            audioFrameListener: { frame in
                try streamController.pushLocalAudioFrame(frame)
            },
            errorListener: {
                errorManager.forward(
                    $0,
                    target: .all
                )
            },
            interactionListener: { taskID, points in
                try await streamController.sendTracks(
                    taskID: taskID,
                    points: points
                )
            }
        )

        let connectionManager = XmaxRealtimeConnectionManager(
            errorManager: errorManager,
            interactionController: mediaController,
            renderController: renderController,
            streamController: streamController,
            sessionService: RealtimeSessionService(apiService: apiService, provider: options.rtcProvider),
            mediaService: mediaService,
            timing: timing
        )

        let generationManager = XmaxRealtimeGenerationManager(
            interactionController: mediaController,
            streamController: streamController,
            renderController: renderController,
            timing: timing
        )
        return assemble(
            connectionManager: connectionManager,
            generationManager: generationManager,
            errorManager: errorManager,
            mediaController: mediaController,
            renderController: renderController,
            streamController: streamController,
            mediaService: mediaService,
            timing: timing
        )
    }

    /// Connects realtime components to shared failure handling and resource cleanup.
    ///
    /// - Parameters:
    ///   - connectionManager: The server session and RTC connection manager.
    ///   - generationManager: The generation request and confirmation manager.
    ///   - errorManager: The shared runtime failure manager.
    ///   - mediaController: The local media and interaction controller.
    ///   - renderController: The remote rendering and output controller.
    ///   - streamController: The RTC publishing and signaling controller.
    ///   - mediaService: The model sizing and capability service.
    ///   - timing: The shared startup duration recorder.
    ///
    /// - Returns: The components with lifecycle admission and cleanup configured.
    static func assemble(
        connectionManager: XmaxRealtimeConnectionManager,
        generationManager: XmaxRealtimeGenerationManager,
        errorManager: XmaxRealtimeErrorManager,
        mediaController: any MediaControlling,
        renderController: any RenderControlling,
        streamController: any StreamControlling,
        mediaService: any MediaServicing,
        timing: RealtimeTiming
    ) -> XmaxRealtimeComponents {
        let lifecycleManager = XmaxRealtimeLifecycleManager(
            errorManager: errorManager,
            cleanup: { scope, taskID in
                if scope == .generation {
                    do {
                        try await generationManager.stop(taskID: taskID)
                    } catch {
                        XmaxLogger.realtime.error(
                            message: """
                                停止实时生成失败 (Failed to Stop Realtime Generation)
                                └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                                """
                        )
                    }

                    return XmaxRealtimeLifecycleManager.CleanupResult(
                        sessionID: await connectionManager.currentSessionID,
                        hasLocalMedia: await mediaController.currentTrack != nil
                    )
                }

                if scope == .all {
                    await mediaController.setLocalAudioPreviewMuted(true)
                }

                do {
                    try await mediaController.stopMicrophoneCapture()
                } catch {
                    XmaxLogger.realtime.error(
                        message: """
                            停止麦克风采集失败 (Failed to Stop Microphone Capture)
                            └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                            """
                    )
                }

                do {
                    try await generationManager.reset(taskID: taskID)
                } catch {
                    XmaxLogger.realtime.error(
                        message: """
                            停止实时生成失败 (Failed to Stop Realtime Generation)
                            └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                            """
                    )
                }

                let activeSessionID = await connectionManager.currentSessionID
                var sessionID = activeSessionID.isEmpty ? nil : activeSessionID

                do {
                    sessionID = try await connectionManager.disconnect() ?? sessionID
                } catch {
                    XmaxLogger.realtime.error(
                        message: """
                            断开实时连接失败 (Failed to Disconnect Realtime)
                            └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                            """
                    )
                }

                if scope == .all {
                    await mediaController.stopLocalStream()
                } else {
                    await mediaController.setLocalAudioPreviewMuted(false)
                    do {
                        try await mediaController.updateCameraOrientation()
                    } catch {
                        XmaxLogger.realtime.error(
                            message: """
                                更新摄像头方向失败 (Failed to Update Camera Orientation)
                                └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                                """
                        )
                    }
                }

                return XmaxRealtimeLifecycleManager.CleanupResult(
                    sessionID: sessionID,
                    hasLocalMedia: await mediaController.currentTrack != nil
                )
            }
        )
        errorManager.setFailureHandler { [weak lifecycleManager] error, target, isCurrent in
            await lifecycleManager?.terminate(
                with: error,
                target: target,
                isCurrent: isCurrent
            )
        }

        return XmaxRealtimeComponents(
            lifecycleManager: lifecycleManager,
            connectionManager: connectionManager,
            generationManager: generationManager,
            errorManager: errorManager,
            mediaController: mediaController,
            renderController: renderController,
            streamController: streamController,
            mediaService: mediaService,
            timing: timing
        )
    }
}
