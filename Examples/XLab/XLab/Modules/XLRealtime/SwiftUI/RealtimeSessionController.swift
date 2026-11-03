import Combine
import Foundation
import XmaxSDK

@MainActor
final class RealtimeSessionController: ObservableObject {

    // 视频轨道
    @Published private(set) var localVideoTrack: RealtimeVideoTrack?
    @Published private(set) var remoteVideoTrack: RealtimeVideoTrack?

    // 统计展示
    let statistics = RealtimeStatisticsStore()

    // 实时状态
    @Published private(set) var connectionState: RealtimeConnectionState = .idle
    @Published private(set) var isGenerationRequested = false
    @Published private(set) var isLoading = true

    // 设备状态
    @Published private(set) var isBackCameraSelected = false
    @Published private(set) var isCameraSwitching = false
    @Published private(set) var isCameraFormatUpdating = false
    @Published private(set) var isFrameInterpolationEnabled: Bool

    // 错误状态
    @Published private(set) var errorMessage: String?

    // 轻提示
    @Published var toastMessage: String?

    // SDK 资源
    private let realtimeManager: any XmaxRealtimeManaging
    private var localMediaStream: RealtimeMediaStream?

    // 生命周期状态
    private var hasStarted = false

    // 异步任务
    private var startupTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var generationRequestID: UUID?
    private var disconnectTask: Task<Void, Never>?
    private var cameraSwitchTask: Task<Void, Never>?
    private var cameraFormatTask: Task<Void, Never>?
    private var frameInterpolationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    var isMediaReady: Bool {
        switch connectionState {
        case .ready, .connecting, .connected, .generating:
            true
        case .disconnecting:
            localMediaStream != nil
        case .idle, .preparing:
            false
        }
    }

    var supportedCameraFormats: [RealtimeVideoFormat] {
        realtimeManager.options.model.supportedVideoFormats
    }

    func updateCameraFormat(_ format: RealtimeVideoFormat) {
        guard connectionState == .ready, !isCameraFormatUpdating else { return }
        isCameraFormatUpdating = true
        cameraFormatTask = Task { [weak self] in
            guard let self else { return }
            defer { isCameraFormatUpdating = false }
            do {
                try await realtimeManager.updateCameraFormat(format)
            } catch {
                guard !Task.isCancelled else { return }
                toastMessage = error.localizedDescription
            }
        }
    }

    init() {
        let initialFrameInterpolationEnabled: Bool
        if #available(iOS 26.0, *) {
            initialFrameInterpolationEnabled = true
        } else {
            initialFrameInterpolationEnabled = false
        }
        isFrameInterpolationEnabled = initialFrameInterpolationEnabled

        let apiKey = UserDefaults.standard.string(
            forKey: RealtimePreferences.apiKeyStorageKey
        ) ?? ""
        let client = XmaxClient(
            configuration: XmaxConfiguration(
                apiKey: apiKey,
                environment: RealtimePreferences.environment,
                loggerOptions: [.business, .performance]
            )
        )
        realtimeManager = client.createRealtimeManager(
            options: RealtimeConfiguration(
                model: RealtimePreferences.selectedModel,
                isFrameInterpolationEnabled: initialFrameInterpolationEnabled
            )
        )
    }

    deinit {
        startupTask?.cancel()
        generationTask?.cancel()
        cameraSwitchTask?.cancel()
        cameraFormatTask?.cancel()
        frameInterpolationTask?.cancel()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let pendingCleanup = cleanupTask
        cleanupTask = nil
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            await pendingCleanup?.value
            guard let self, hasStarted, !Task.isCancelled else { return }

            await realtimeManager.setStateListener { [weak self] state in
                self?.renderRealtimeState(state)
            }
            await statistics.observe(realtimeManager)
            do {
                let stream = try await realtimeManager.createLocalCameraStream(
                    videoFormat: RealtimePreferences.cameraVideoFormat,
                    position: .front,
                    useMicrophone: true
                )
                guard hasStarted, !Task.isCancelled else { return }
                localMediaStream = stream
                localVideoTrack = stream.videoTrack
                isFrameInterpolationEnabled =
                    await realtimeManager.isFrameInterpolationEnabled
            } catch {
                guard hasStarted, !Task.isCancelled else { return }
                handleRealtimeError(XmaxError.from(error))
            }
        }
    }

    func startGeneration(context: RealtimeContext, faceRestoration: Bool = false) {
        guard let localMediaStream else {
            errorMessage = XLLocalization.text("realtime.media.notReady")
            return
        }

        isGenerationRequested = true
        isLoading = true

        let requestID = UUID()
        generationRequestID = requestID
        let pendingDisconnect = disconnectTask
        generationTask = Task { [weak self] in
            await pendingDisconnect?.value
            guard let self, generationRequestID == requestID, !Task.isCancelled else { return }
            defer {
                if generationRequestID == requestID {
                    generationRequestID = nil
                    generationTask = nil
                }
            }

            do {
                let remoteStream = try await realtimeManager.startGeneration(
                    localStream: localMediaStream,
                    context: context,
                    faceRestoration: faceRestoration
                )
                guard generationRequestID == requestID, isGenerationRequested, !Task.isCancelled else { return }
                remoteVideoTrack = remoteStream.videoTrack
                isLoading = false
            } catch {
                let resolvedError = XmaxError.from(error)
                guard generationRequestID == requestID, isGenerationRequested,
                      !Task.isCancelled, resolvedError.code != .cancelled else { return }
                let state = await realtimeManager.currentState
                guard generationRequestID == requestID, isGenerationRequested, !Task.isCancelled else { return }
                if state.connectionState != .generating {
                    isGenerationRequested = false
                    remoteVideoTrack = nil
                }
                isLoading = false
                handleRealtimeError(resolvedError)
            }
        }
    }

    func disconnectGeneration() {
        guard isGenerationRequested || remoteVideoTrack != nil else { return }

        isGenerationRequested = false
        remoteVideoTrack = nil
        isLoading = connectionState == .preparing

        generationRequestID = nil
        let pendingGeneration = generationTask
        pendingGeneration?.cancel()
        generationTask = nil
        let previousDisconnect = disconnectTask
        let realtimeManager = realtimeManager
        disconnectTask = Task {
            await previousDisconnect?.value
            await realtimeManager.disconnect()
            await pendingGeneration?.value
        }
    }

    func switchCamera() {
        guard localMediaStream != nil, !isCameraSwitching else { return }

        isCameraSwitching = true
        let retainedRemoteVideoTrack = remoteVideoTrack
        if isGenerationRequested {
            remoteVideoTrack = nil
            isLoading = true
        }
        cameraSwitchTask?.cancel()
        cameraSwitchTask = Task { [weak self] in
            guard let self else { return }
            defer { isCameraSwitching = false }
            do {
                let stream = try await realtimeManager.switchCamera()
                guard !Task.isCancelled else { return }
                localMediaStream = stream
                localVideoTrack = stream.videoTrack
                isBackCameraSelected.toggle()
                if isGenerationRequested {
                    remoteVideoTrack = retainedRemoteVideoTrack
                    isLoading = false
                } else {
                    isLoading = connectionState == .preparing
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if !isGenerationRequested {
                    isLoading = connectionState == .preparing
                }
                handleRealtimeError(XmaxError.from(error))
            }
        }
    }

    func setFrameInterpolationEnabled(_ enabled: Bool) {
        frameInterpolationTask?.cancel()
        frameInterpolationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await realtimeManager.setFrameInterpolationEnabled(enabled)
            } catch {
                guard !Task.isCancelled else { return }
                let resolvedError = XmaxError.from(error)
                if resolvedError.code != .cancelled {
                    errorMessage = resolvedError.localizedDescription
                }
            }
            guard !Task.isCancelled else { return }
            isFrameInterpolationEnabled =
                await realtimeManager.isFrameInterpolationEnabled
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func close() {
        guard hasStarted else { return }
        hasStarted = false

        let pendingStartup = startupTask
        let pendingGeneration = generationTask
        let pendingDisconnect = disconnectTask
        disconnectTask = nil
        generationRequestID = nil
        let pendingCameraSwitch = cameraSwitchTask
        let pendingCameraFormat = cameraFormatTask
        cameraFormatTask?.cancel()
        cameraFormatTask = nil
        let pendingFrameInterpolation = frameInterpolationTask
        startupTask?.cancel()
        startupTask = nil
        generationTask?.cancel()
        generationTask = nil
        cameraSwitchTask?.cancel()
        cameraSwitchTask = nil
        frameInterpolationTask?.cancel()
        frameInterpolationTask = nil

        localMediaStream = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        connectionState = .idle
        statistics.clear()
        isGenerationRequested = false
        isLoading = false
        isBackCameraSelected = false
        isCameraSwitching = false

        let realtimeManager = realtimeManager
        let statistics = statistics
        cleanupTask = Task {
            await pendingStartup?.value
            await pendingDisconnect?.value
            await pendingGeneration?.value
            await pendingCameraSwitch?.value
            await pendingCameraFormat?.value
            await pendingFrameInterpolation?.value
            await realtimeManager.setUplinkVideoStatisticsListener(nil)
            await realtimeManager.setDownlinkVideoStatisticsListener(nil)
            await realtimeManager.setNetworkQualityListener(nil)
            statistics.clear()
            await realtimeManager.setStateListener(nil)
            await realtimeManager.close()
        }
    }

    private func renderRealtimeState(_ state: RealtimeState) {
        statistics.updateState(state)
        connectionState = state.connectionState
        if let reason = state.reason, reason != .normal {
            isGenerationRequested = false
        }
        if state.connectionState == .idle {
            localMediaStream = nil
            localVideoTrack = nil
        }
        switch state.connectionState {
        case .preparing:
            isLoading = true
        case .connecting, .connected:
            if isGenerationRequested {
                remoteVideoTrack = nil
                isLoading = true
            }
        case .generating:
            guard isGenerationRequested else { return }
            if remoteVideoTrack != nil {
                isLoading = false
            }
        case .disconnecting:
            remoteVideoTrack = nil
            if !isGenerationRequested { isLoading = false }
        case .idle, .ready:
            if !isGenerationRequested {
                remoteVideoTrack = nil
                isLoading = false
            }
        }
        if state.connectionState == .idle { isLoading = false }
        if case .failure(let error) = state.reason {
            handleRealtimeError(error)
        } else if state.reason == .orientationChanged {
            toastMessage = XLLocalization.text("realtime.orientation.changed")
        }
    }

    private func handleRealtimeError(_ error: XmaxError) {
        guard error.code != .cancelled else { return }
        errorMessage = error.localizedDescription
    }
}
