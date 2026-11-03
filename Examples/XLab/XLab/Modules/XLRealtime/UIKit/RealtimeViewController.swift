import Photos
import PhotosUI
import SnapKit
import SwiftUI
import UIKit
import XmaxSDK

final class RealtimeViewController: UIViewController, UIGestureRecognizerDelegate {

    private enum ReferencePickerDestination {
        case category(String)
        case prompt
    }

    private static var initialFrameInterpolationEnabled: Bool {
        if #available(iOS 26.0, *) {
            true
        } else {
            false
        }
    }

    // 实时资源
    private var localInput: RealtimeLocalInput?
    private let trajectoryStyle: RealtimeTrajectoryStyle
    private let realtimeManager: any XmaxRealtimeManaging
    private var localMediaStream: RealtimeMediaStream?
    private var remoteVideoTrack: RealtimeVideoTrack?
    private var selectedReference: RealtimeReferenceCatalog.Item?
    private var currentGenerationContext: RealtimeContext?
    private var isGenerationRequested = false
    private var isTouchAnimationGenerationRequested = false
    private var connectionState: RealtimeConnectionState = .idle
    private var isSuspendedForBackground = false

    // 统计展示
    private let statistics = RealtimeStatisticsStore()
    private var isStatisticsVisible = false
    private lazy var statisticsPanel: UIHostingController<RealtimeStatisticsPanel> = UIHostingController(
        rootView: RealtimeStatisticsPanel(statistics: statistics) { [weak self] height in
            self?.statisticsPanel.view.snp.updateConstraints { make in
                make.height.equalTo(height).priority(750)
            }
        }
    )

    // 音频状态
    private var localAudioVolume: Float?
    private var remoteAudioVolume: Float?
    private var isAudioMuted = false

    // 录制资源
    private lazy var videoRecorder = RealtimeVideoRecorder { [weak self] error in
        Task { @MainActor [weak self] in
            self?.handleRecordingFailure(error)
        }
    }

    // 录制状态
    private var recordingButtonState = RealtimeRecordingButtonState.idle

    // 触控动图
    private var touchAnimationReferencePath: String?

    // 参考图状态
    private var referencePickerDestination: ReferencePickerDestination?
    private var promptReference: RealtimeReferenceCatalog.Item?
    private var referenceUploadRequestIDs: [String: UUID] = [:]

    // 本地素材选择
    private lazy var localMediaPicker = RealtimeLocalMediaPicker()

    // 异步任务
    private var localMediaOperationTask: Task<Void, Never>?
    private var cameraFormatTask: Task<Void, Never>?
    private var generationOperationTask: Task<Void, Never>?
    private var generationRequestID: UUID?
    private var disconnectTask: Task<Void, Never>?
    private var touchAnimationPreparationTask: Task<Void, Never>?
    private var realtimeListenerTask: Task<Void, Never>?
    private var mediaCleanupTask: Task<Void, Never>?
    private var localAudioVolumeTask: Task<Void, Never>?
    private var remoteAudioVolumeTask: Task<Void, Never>?
    private var audioVolumeStateTask: Task<Void, Never>?
    private var frameInterpolationTask: Task<Void, Never>?
    private var recordingOperationTask: Task<Void, Never>?
    private var referenceUploadTasks: [String: Task<Void, Never>] = [:]

    // 布局约束
    private var promptKeyboardBottomConstraint: Constraint?

    // 交互手势
    private lazy var keyboardDismissTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(
            target: self,
            action: #selector(dismissKeyboard)
        )
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()

    private lazy var keyboardDismissSwipeGesture: UISwipeGestureRecognizer = {
        let gesture = UISwipeGestureRecognizer(
            target: self,
            action: #selector(dismissKeyboard)
        )
        gesture.direction = .down
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()

    // 界面组件
    private lazy var previewView = RealtimePreviewBackdropView(
        usesFileLayout: localInput != nil,
        trajectoryRenderer: trajectoryStyle == .xLabCustom
            ? Self.makeCustomTrajectoryRenderer()
            : nil
    )

    private lazy var controlPanelView: RealtimeControlPanelView = {
        let initialMode: RealtimeControlPanelView.InitialMode =
            localInput?.kind == .image ? .touchAnimation : .standard
        let view = RealtimeControlPanelView(initialMode: initialMode)
        view.isUserInteractionEnabled = false
        view.onBeginPromptEditing = { [weak self] text in
            self?.showPromptKeyboard(text: text)
        }
        view.onPromptSubmit = { [weak self] text in
            self?.submitPrompt(text)
        }
        view.onReferenceSelectionChanged = { [weak self] reference in
            self?.handleReferenceSelection(reference)
        }
        view.onAddReference = { [weak self] categoryID in
            self?.presentReferencePhotoPicker(
                destination: .category(categoryID)
            )
        }
        view.onRetryReferenceUpload = { [weak self] reference in
            self?.startReferenceUpload(reference)
        }
        view.onPromptReferenceAction = { [weak self] in
            self?.handlePromptReferenceAction()
        }
        view.onInstructionAction = { [weak self] in
            self?.startTouchAnimationGeneration()
        }
        view.onDisableGeneration = { [weak self] in
            guard let self else { return }
            selectedReference = nil
            disconnectGeneration()
        }
        return view
    }()

    private lazy var promptKeyboardView: RealtimePromptKeyboardView = {
        let view = RealtimePromptKeyboardView()
        view.isHidden = true
        view.onTextChange = { [weak self] text in
            self?.controlPanelView.setPromptText(text)
        }
        view.onSubmit = { [weak self] text in
            guard let self else { return }
            controlPanelView.setPromptText(text)
            promptKeyboardView.endEditing()
            submitPrompt(text)
        }
        view.onReferenceAction = { [weak self] in
            self?.handlePromptReferenceAction()
        }
        return view
    }()

    private lazy var cameraActionBar: RealtimeCameraActionBar = {
        let actionBar = RealtimeCameraActionBar()
        actionBar.isHidden = localInput != nil
        actionBar.setSwitchCameraEnabled(false)
        actionBar.onSwitchCamera = { [weak self] in
            self?.switchCamera()
        }
        actionBar.onOpenCameraFormat = { [weak self] sourceView in
            self?.presentCameraFormatMenu(from: sourceView)
        }
        actionBar.onFrameInterpolationChanged = { [weak self] enabled in
            self?.setFrameInterpolationEnabled(enabled)
        }
        actionBar.onOpenAudioVolume = { [weak self] sourceView in
            self?.presentAudioVolumeMenu(from: sourceView)
        }
        actionBar.onToggleStatistics = { [weak self] in
            self?.toggleStatistics()
        }
        actionBar.setFrameInterpolationEnabled(
            Self.initialFrameInterpolationEnabled
        )
        return actionBar
    }()

    private lazy var mediaTopBar: RealtimeMediaTopBar = {
        let topBar = RealtimeMediaTopBar(
            showsVideoControls: localInput?.kind == .video
        )
        topBar.isHidden = localInput == nil
        topBar.onOpenGallery = { [weak self] in
            self?.presentLocalMediaPicker()
        }
        topBar.onOpenAudioVolume = { [weak self] sourceView in
            self?.presentAudioVolumeMenu(from: sourceView)
        }
        topBar.onToggleRecording = { [weak self] in
            self?.toggleRecording()
        }
        topBar.onMuteChanged = { [weak self] muted in
            self?.setAudioMuted(muted)
        }
        topBar.onFrameInterpolationChanged = { [weak self] enabled in
            self?.setFrameInterpolationEnabled(enabled)
        }
        topBar.onToggleStatistics = { [weak self] in
            self?.toggleStatistics()
        }
        topBar.setFrameInterpolationEnabled(
            Self.initialFrameInterpolationEnabled
        )
        return topBar
    }()

    private func setFrameInterpolationEnabled(_ enabled: Bool) {
        frameInterpolationTask?.cancel()
        frameInterpolationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await realtimeManager.setFrameInterpolationEnabled(
                    enabled
                )
                guard !Task.isCancelled else { return }
                cameraActionBar.setFrameInterpolationEnabled(enabled)
                mediaTopBar.setFrameInterpolationEnabled(enabled)
            } catch {
                guard !Task.isCancelled else { return }
                let currentValue =
                    await realtimeManager.isFrameInterpolationEnabled
                cameraActionBar.setFrameInterpolationEnabled(currentValue)
                mediaTopBar.setFrameInterpolationEnabled(currentValue)
                let resolvedError = XmaxError.from(error)
                if resolvedError.code != .cancelled {
                    XLToast.show(resolvedError.localizedDescription, in: view)
                }
            }
        }
    }

    private func presentAudioVolumeMenu(from sourceView: UIView) {
        guard presentedViewController == nil else { return }

        audioVolumeStateTask?.cancel()
        let realtimeManager = realtimeManager
        audioVolumeStateTask = Task { @MainActor [weak self, weak sourceView] in
            guard let self, let sourceView else { return }
            let volumes = await resolveAudioVolumes(
                realtimeManager: realtimeManager
            )
            guard !Task.isCancelled,
                  presentedViewController == nil,
                  sourceView.window != nil else {
                return
            }
            localAudioVolume = volumes.local
            remoteAudioVolume = volumes.remote

            let menu = RealtimeAudioVolumeMenuViewController(
                localVolume: localInput?.kind == .video && localInput?.usesExternalSource != true
                    ? volumes.local : nil,
                remoteVolume: volumes.remote
            )
            menu.onLocalVolumeChanged = { [weak self] volume in
                self?.setLocalAudioVolume(volume)
            }
            menu.onRemoteVolumeChanged = { [weak self] volume in
                self?.setRemoteAudioVolume(volume)
            }
            if let popover = menu.popoverPresentationController {
                popover.delegate = menu
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
                popover.permittedArrowDirections = localInput == nil ? .right : .up
            }
            present(menu, animated: true)
        }
    }

    private func setAudioMuted(_ muted: Bool) {
        isAudioMuted = muted
        audioVolumeStateTask?.cancel()
        let realtimeManager = realtimeManager
        audioVolumeStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let volumes = await resolveAudioVolumes(
                realtimeManager: realtimeManager
            )
            guard !Task.isCancelled else { return }
            localAudioVolume = volumes.local
            remoteAudioVolume = volumes.remote
            applyLocalAudioVolume(muted ? 0 : volumes.local)
            applyRemoteAudioVolume(muted ? 0 : volumes.remote)
        }
    }

    private func setLocalAudioVolume(_ volume: Float) {
        localAudioVolume = volume
        if isAudioMuted {
            isAudioMuted = false
            mediaTopBar.setMuted(false)
            if let remoteAudioVolume {
                applyRemoteAudioVolume(remoteAudioVolume)
            }
        }
        applyLocalAudioVolume(volume)
    }

    private func setRemoteAudioVolume(_ volume: Float) {
        remoteAudioVolume = volume
        if isAudioMuted {
            isAudioMuted = false
            mediaTopBar.setMuted(false)
            if let localAudioVolume {
                applyLocalAudioVolume(localAudioVolume)
            }
        }
        applyRemoteAudioVolume(volume)
    }

    private func applyLocalAudioVolume(_ volume: Float) {
        localAudioVolumeTask?.cancel()
        let realtimeManager = realtimeManager
        localAudioVolumeTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            try? await realtimeManager.setLocalAudioVolume(volume)
        }
    }

    private func applyRemoteAudioVolume(_ volume: Float) {
        remoteAudioVolumeTask?.cancel()
        let realtimeManager = realtimeManager
        remoteAudioVolumeTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            try? await realtimeManager.setRemoteAudioVolume(volume)
        }
    }

    private func resolveAudioVolumes(
        realtimeManager: any XmaxRealtimeManaging
    ) async -> (local: Float, remote: Float) {
        async let currentLocalVolume = realtimeManager.localAudioVolume
        async let currentRemoteVolume = realtimeManager.remoteAudioVolume
        let fetchedLocalVolume = await currentLocalVolume
        let fetchedRemoteVolume = await currentRemoteVolume
        return (
            localAudioVolume ?? fetchedLocalVolume,
            remoteAudioVolume ?? fetchedRemoteVolume
        )
    }

    private func toggleRecording() {
        switch recordingButtonState {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndSave()
        case .preparing, .saving:
            break
        }
    }

    private func startRecording() {
        guard isGenerationRequested else {
            XLToast.show(XLLocalization.text("record.generation.required"), in: view)
            return
        }

        setRecordingButtonState(.preparing)
        let videoRecorder = videoRecorder
        recordingOperationTask?.cancel()
        recordingOperationTask = Task { @MainActor [weak self] in
            do {
                try await Self.ensurePhotoLibraryAccess()
                try Task.checkCancellation()
                try videoRecorder.start()
                guard !Task.isCancelled else {
                    _ = try? await videoRecorder.stop()
                    return
                }
                guard let self else { return }
                setRecordingButtonState(.recording)
            } catch is CancellationError {
                self?.setRecordingButtonState(.idle)
            } catch {
                guard let self else { return }
                setRecordingButtonState(.idle)
                XLToast.show(error.localizedDescription, in: view)
            }
        }
    }

    private func stopRecordingAndSave() {
        guard recordingButtonState == .recording else { return }
        setRecordingButtonState(.saving)
        let videoRecorder = videoRecorder
        recordingOperationTask = Task { @MainActor [weak self] in
            do {
                let outputURL = try await videoRecorder.stop()
                defer { try? FileManager.default.removeItem(at: outputURL) }
                try await Self.saveVideoToPhotoLibrary(outputURL)
                guard let self else { return }
                setRecordingButtonState(.idle)
                XLToast.show(XLLocalization.text("record.saved"), in: view)
            } catch {
                guard let self else { return }
                setRecordingButtonState(.idle)
                XLToast.show(error.localizedDescription, in: view)
            }
        }
    }

    private func handleRecordingFailure(
        _ error: RealtimeVideoRecorder.RecorderError
    ) {
        guard recordingButtonState == .recording else { return }
        setRecordingButtonState(.idle)
        XLToast.show(error.localizedDescription, in: view)
    }

    private func setRecordingButtonState(
        _ state: RealtimeRecordingButtonState
    ) {
        recordingButtonState = state
        mediaTopBar.setRecordingState(state)
    }

    private nonisolated static func ensurePhotoLibraryAccess() async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status: PHAuthorizationStatus
        if currentStatus == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) {
                    continuation.resume(returning: $0)
                }
            }
        } else {
            status = currentStatus
        }
        guard status == .authorized || status == .limited else {
            throw RealtimeDemoError.photoLibraryPermissionDenied
        }
    }

    private nonisolated static func saveVideoToPhotoLibrary(
        _ fileURL: URL
    ) async throws {
        try await ensurePhotoLibraryAccess()
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: fileURL
                )
            } completionHandler: { succeeded, error in
                if succeeded {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? RealtimeDemoError.videoSaveFailed
                    )
                }
            }
        }
    }

    private lazy var realtimeErrorAlert: UIAlertController = {
        let alert = UIAlertController(
            title: XLLocalization.text("realtime.error.title"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: XLLocalization.text("common.confirm"), style: .default))
        return alert
    }()

    private lazy var loadingOverlay = RealtimeLoadingOverlay()

    init(
        localInput: RealtimeLocalInput? = nil,
        trajectoryStyle: RealtimeTrajectoryStyle = .sdkDefault
    ) {
        self.localInput = localInput
        self.trajectoryStyle = trajectoryStyle
        realtimeManager = Self.makeRealtimeManager()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configurePreview()
        configureTopControls()
        configureControlPanel()
        configureStatisticsPanel()
        configurePromptKeyboard()
        configureKeyboardDismissal()
        observeNotifications()
        controlPanelView.isUserInteractionEnabled = false
        observeRealtimeEvents()
        startLocalMedia()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        resumeRealtimeAfterBackgroundIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            closeRealtime()
        }
    }

    deinit {
        cameraFormatTask?.cancel()
        audioVolumeStateTask?.cancel()
        localAudioVolumeTask?.cancel()
        remoteAudioVolumeTask?.cancel()
        frameInterpolationTask?.cancel()
        recordingOperationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func configurePreview() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        previewView.snp.makeConstraints { make in
            make.horizontalEdges.equalToSuperview()
            if localInput == nil {
                make.top.equalToSuperview()
            } else {
                make.top.equalTo(view.safeAreaLayoutGuide)
                    .offset(68)
            }
        }

        previewView.addSubview(loadingOverlay)
        loadingOverlay.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func configureTopControls() {
        let backButton = UIButton(type: .custom)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(named: "realtime_nav_back"), for: .normal)
        backButton.imageView?.contentMode = .scaleAspectFit
        backButton.accessibilityLabel = XLLocalization.text("common.home")
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        view.addSubview(backButton)

        view.addSubview(cameraActionBar)
        view.addSubview(mediaTopBar)

        backButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            make.leading.equalToSuperview().offset(12)
            make.size.equalTo(44)
        }
        cameraActionBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(6)
            make.trailing.equalToSuperview().inset(8)
            make.width.equalTo(58)
            make.height.equalTo(296).priority(750)
            make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(-94)
        }
        mediaTopBar.snp.makeConstraints { make in
            make.centerY.equalTo(backButton)
            make.leading.greaterThanOrEqualTo(backButton.snp.trailing).offset(8)
            make.trailing.equalTo(view.safeAreaLayoutGuide).inset(12)
        }
    }

    private func configureControlPanel() {
        controlPanelView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlPanelView)

        controlPanelView.snp.makeConstraints { make in
            make.horizontalEdges.bottom.equalToSuperview()
        }
        previewView.snp.makeConstraints { make in
            make.bottom.equalTo(controlPanelView.snp.top)
        }

    }

    private func toggleStatistics() {
        isStatisticsVisible.toggle()
        statisticsPanel.view.isHidden = !isStatisticsVisible
        cameraActionBar.setStatisticsVisible(isStatisticsVisible)
        mediaTopBar.setStatisticsVisible(isStatisticsVisible)
    }

    private func configureStatisticsPanel() {
        addChild(statisticsPanel)
        statisticsPanel.view.backgroundColor = .clear
        statisticsPanel.view.isHidden = true
        view.addSubview(statisticsPanel.view)
        statisticsPanel.view.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(64)
            make.leading.equalTo(view.safeAreaLayoutGuide).offset(12)
            make.width.equalTo(184)
            make.height.equalTo(0).priority(750)
            make.height.greaterThanOrEqualTo(0)
            make.bottom.lessThanOrEqualTo(controlPanelView.snp.top).offset(-8)
        }
        statisticsPanel.didMove(toParent: self)
    }

    private func configurePromptKeyboard() {
        view.addSubview(promptKeyboardView)
        promptKeyboardView.snp.makeConstraints { make in
            make.horizontalEdges.equalToSuperview()
            make.height.equalTo(RealtimePromptKeyboardView.preferredHeight)
            promptKeyboardBottomConstraint = make.bottom.equalToSuperview()
                .offset(RealtimePromptKeyboardView.preferredHeight)
                .constraint
        }
    }

    private func configureKeyboardDismissal() {
        view.addGestureRecognizer(keyboardDismissTapGesture)
        view.addGestureRecognizer(keyboardDismissSwipeGesture)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var touchedView = touch.view
        while let currentView = touchedView, currentView !== view {
            if currentView === promptKeyboardView ||
                currentView is UIControl ||
                currentView is UIScrollView {
                return false
            }
            touchedView = currentView.superview
        }
        return true
    }

    private func observeRealtimeEvents() {
        let pendingCleanup = mediaCleanupTask
        let realtimeManager = realtimeManager
        let videoRecorder = videoRecorder
        realtimeListenerTask?.cancel()
        realtimeListenerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await pendingCleanup?.value
            guard !Task.isCancelled else { return }
            await realtimeManager.setStateListener { [weak self] state in
                self?.renderRealtimeState(state)
            }
            await statistics.observe(realtimeManager)
            do {
                try await realtimeManager.setRemoteMediaFrameListener { frame in
                    videoRecorder.append(frame)
                }
            } catch {
                XLToast.show(error.localizedDescription, in: view)
            }
        }
    }

    private func presentRealtimeError(_ error: XmaxError) {
        guard error.code != .cancelled else { return }
        if error.code == .frameInterpolationUnsupported {
            XLToast.show(error.localizedDescription, in: view)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let enabled =
                    await realtimeManager.isFrameInterpolationEnabled
                cameraActionBar.setFrameInterpolationEnabled(enabled)
                mediaTopBar.setFrameInterpolationEnabled(enabled)
            }
            return
        }
        guard
              presentedViewController == nil else {
            return
        }
        realtimeErrorAlert.message = error.localizedDescription
        present(realtimeErrorAlert, animated: true)
    }

    private func renderRealtimeState(_ state: RealtimeState) {
        statistics.updateState(state)
        connectionState = state.connectionState
        cameraActionBar.setCameraFormatEnabled(localInput == nil && connectionState == .ready && cameraFormatTask == nil)
        controlPanelView.isUserInteractionEnabled =
            state.connectionState != .idle &&
            state.connectionState != .preparing &&
            (state.connectionState != .disconnecting || localMediaStream != nil)
        if let reason = state.reason, reason != .normal {
            isGenerationRequested = false
            isTouchAnimationGenerationRequested = false
            controlPanelView.setGenerationActive(false)
            currentGenerationContext = nil
            selectedReference = nil
            controlPanelView.clearReferenceSelection()
        }
        if state.connectionState == .idle {
            localMediaStream = nil
            previewView.displayLocal(nil)
        }
        switch state.connectionState {
        case .preparing:
            loadingOverlay.startLoading()
        case .connecting, .connected:
            if isGenerationRequested {
                previewView.hideRealtime()
                loadingOverlay.startLoading()
            }
        case .generating:
            guard isGenerationRequested,
                  let remoteVideoTrack else {
                return
            }
            previewView.displayRealtime(remoteVideoTrack)
            loadingOverlay.hideLoading()
        case .idle, .ready, .disconnecting:
            remoteVideoTrack = nil
            previewView.hideRealtime()
            if recordingButtonState == .recording {
                stopRecordingAndSave()
            } else if recordingButtonState == .preparing {
                recordingOperationTask?.cancel()
                setRecordingButtonState(.idle)
            }
            renderPreviewLoadingState()
            if state.connectionState == .idle { loadingOverlay.hideLoading() }
        }
        if case .failure(let error) = state.reason {
            presentRealtimeError(error)
        } else if state.reason == .orientationChanged {
            XLToast.show(XLLocalization.text("realtime.orientation.changed"), in: view)
        }
    }

    private func renderPreviewLoadingState() {
        if connectionState == .disconnecting {
            if !isGenerationRequested { loadingOverlay.hideLoading() }
            return
        }

        if connectionState == .preparing || isGenerationRequested {
            loadingOverlay.startLoading()
        } else {
            loadingOverlay.hideLoading()
        }
    }

    private func showPromptKeyboard(text: String) {
        promptKeyboardView.isHidden = false
        promptKeyboardView.alpha = 0
        promptKeyboardView.beginEditing(text: text)
    }

    private static func makeRealtimeManager() -> any XmaxRealtimeManaging {
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
        return client.createRealtimeManager(
            options: RealtimeConfiguration(
                model: RealtimePreferences.selectedModel,
                isFrameInterpolationEnabled:
                    Self.initialFrameInterpolationEnabled
            )
        )
    }

    private func presentReferencePhotoPicker(
        destination: ReferencePickerDestination
    ) {
        guard referencePickerDestination == nil,
              presentedViewController == nil else {
            return
        }

        referencePickerDestination = destination
        view.endEditing(true)

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    func finishReferencePicking(
        localURL: URL?,
        error: (any Error)? = nil
    ) {
        let destination = referencePickerDestination
        referencePickerDestination = nil

        if error != nil {
            XLToast.show(XLLocalization.text("realtime.photo.error"), in: view)
            return
        }
        guard let localURL, let destination else { return }

        switch destination {
        case let .category(categoryID):
            let reference = RealtimeReferenceCatalog.Item(
                categoryID: categoryID,
                iconURL: localURL,
                prompt: RealtimeCategory.defaultPrompt(
                    for: categoryID
                )
            )
            controlPanelView.insertReference(reference)
            startReferenceUpload(reference)
        case .prompt:
            if let promptReference {
                cancelReferenceUpload(promptReference)
            }
            let reference = RealtimeReferenceCatalog.Item(
                categoryID: "free",
                iconURL: localURL,
                prompt: ""
            )
            promptReference = reference
            renderPromptReference()
            startReferenceUpload(reference)
        }
    }

    private func handleReferenceSelection(
        _ reference: RealtimeReferenceCatalog.Item?
    ) {
        let previousReference = selectedReference
        selectedReference = reference
        guard let reference else {
            if previousReference?.context == currentGenerationContext {
                disconnectGeneration()
            }
            return
        }

        switch reference.uploadState {
        case .ready:
            guard let context = reference.context else { return }
            startGeneration(
                context: context,
                selectedReferenceID: reference.id,
                faceRestoration: reference.categoryID == "clothx"
            )
        case .uploading:
            break
        case .failed:
            startReferenceUpload(reference)
        }
    }

    private func handlePromptReferenceAction() {
        guard let promptReference else {
            presentReferencePhotoPicker(destination: .prompt)
            return
        }

        switch promptReference.uploadState {
        case .uploading:
            return
        case .failed:
            startReferenceUpload(promptReference)
        case .ready:
            cancelReferenceUpload(promptReference)
            self.promptReference = nil
            renderPromptReference()
        }
    }

    private func submitPrompt(_ text: String) {
        let prompt = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let canUsePromptReference = promptReference == nil
            || promptReference?.uploadState == .ready
        guard !prompt.isEmpty, canUsePromptReference else {
            return
        }
        selectedReference = nil
        controlPanelView.clearReferenceSelection()
        startGeneration(
            context: RealtimeContext(
                prompt: prompt,
                referencePath: promptReference?.referencePath
            ),
            selectedReferenceID: nil
        )
    }

    private func startTouchAnimationGeneration() {
        guard !isGenerationRequested else { return }

        selectedReference = nil
        controlPanelView.clearReferenceSelection()
        isGenerationRequested = true
        isTouchAnimationGenerationRequested = true
        controlPanelView.setGenerationActive(true)
        loadingOverlay.startLoading()

        touchAnimationPreparationTask?.cancel()
        let input = localInput
        touchAnimationPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let referencePath = try await resolveTouchAnimationReferencePath(
                    for: input
                )
                try Task.checkCancellation()
                touchAnimationPreparationTask = nil
                startGeneration(
                    context: RealtimeContext(
                        prompt: RealtimeCategory.defaultPrompt(for: "mox"),
                        referencePath: referencePath
                    ),
                    selectedReferenceID: nil,
                    isTouchAnimation: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                touchAnimationPreparationTask = nil
                isGenerationRequested = false
                isTouchAnimationGenerationRequested = false
                controlPanelView.setGenerationActive(false)
                renderPreviewLoadingState()
                XLToast.show(error.localizedDescription, in: view)
            }
        }
    }

    private func resolveTouchAnimationReferencePath(
        for input: RealtimeLocalInput?
    ) async throws -> String? {
        guard case let .image(image) = input else { return nil }
        if let touchAnimationReferencePath {
            return touchAnimationReferencePath
        }

        guard let imageData = image.jpegData(compressionQuality: 0.92) else {
            throw RealtimeDemoError.imageEncodingFailed
        }
        let apiKey = UserDefaults.standard.string(
            forKey: RealtimePreferences.apiKeyStorageKey
        ) ?? ""
        let client = XmaxClient(
            configuration: XmaxConfiguration(
                apiKey: apiKey,
                environment: RealtimePreferences.environment,
                loggerOptions: .business
            )
        )
        let storageManager = try client.createStorageManager()
        let uploaded = try await storageManager.uploadImage(
            imageData,
            fileName: "touch-animation-\(UUID().uuidString).jpg",
            contentType: "image/jpeg",
            progress: nil
        )
        try Task.checkCancellation()
        let referencePath = uploaded.url.absoluteString
        touchAnimationReferencePath = referencePath
        return referencePath
    }

    private func startReferenceUpload(
        _ reference: RealtimeReferenceCatalog.Item
    ) {
        cancelReferenceUpload(reference)

        reference.uploadState = .uploading
        let requestID = UUID()
        referenceUploadRequestIDs[reference.id] = requestID
        renderReference(reference)

        let apiKey = UserDefaults.standard.string(
            forKey: RealtimePreferences.apiKeyStorageKey
        ) ?? ""
        let fileURL = reference.iconURL
        referenceUploadTasks[reference.id] = Task { [weak self, reference] in
            do {
                let client = XmaxClient(
                    configuration: XmaxConfiguration(
                        apiKey: apiKey,
                        environment: RealtimePreferences.environment,
                        loggerOptions: .business
                    )
                )
                let storageManager = try client.createStorageManager()
                let uploaded = try await storageManager.uploadImage(
                    at: fileURL,
                    contentType: nil,
                    progress: nil
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self, reference] in
                    self?.finishReferenceUpload(
                        reference,
                        requestID: requestID,
                        result: .success(uploaded.url)
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self, reference] in
                    self?.finishReferenceUpload(
                        reference,
                        requestID: requestID,
                        result: .failure(error)
                    )
                }
            }
        }
    }

    private func finishReferenceUpload(
        _ reference: RealtimeReferenceCatalog.Item,
        requestID: UUID,
        result: Result<URL, Error>
    ) {
        guard referenceUploadRequestIDs[reference.id] == requestID else {
            return
        }
        referenceUploadRequestIDs[reference.id] = nil
        referenceUploadTasks[reference.id] = nil

        switch result {
        case let .success(remoteURL):
            reference.referencePath = remoteURL.absoluteString
            reference.uploadState = .ready
            renderReference(reference)

            if reference === promptReference {
                return
            }
            if controlPanelView.isReferenceSelected(reference.id),
               let context = reference.context {
                startGeneration(
                    context: context,
                    selectedReferenceID: reference.id,
                    faceRestoration: reference.categoryID == "clothx"
                )
            }
        case .failure:
            reference.uploadState = .failed
            renderReference(reference)
            XLToast.show(
                XLLocalization.text("realtime.reference.error"),
                in: view
            )
        }
    }

    private func cancelReferenceUpload(
        _ reference: RealtimeReferenceCatalog.Item
    ) {
        referenceUploadTasks[reference.id]?.cancel()
        referenceUploadTasks[reference.id] = nil
        referenceUploadRequestIDs[reference.id] = nil
    }

    private func renderReference(
        _ reference: RealtimeReferenceCatalog.Item
    ) {
        if reference === promptReference {
            renderPromptReference()
        } else {
            controlPanelView.updateReference(reference)
        }
    }

    private func renderPromptReference() {
        controlPanelView.setPromptReference(promptReference)
        promptKeyboardView.setReference(promptReference)
    }

    private func presentCameraFormatMenu(from sourceView: UIView) {
        guard localInput == nil, connectionState == .ready, cameraFormatTask == nil else { return }
        let current = localMediaStream?.videoTrack?.videoFormat
        let menu = UIAlertController(
            title: XLLocalization.text("realtime.camera.format"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for format in realtimeManager.options.model.supportedVideoFormats {
            let selected = current?.width == format.width && current?.height == format.height
            let title = RealtimePreferences.cameraAspectRatioLabel(for: format) + (selected ? " ✓" : "")
            menu.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.updateCameraFormat(format)
            })
        }
        menu.addAction(UIAlertAction(title: XLLocalization.text("common.cancel"), style: .cancel))
        menu.popoverPresentationController?.sourceView = sourceView
        menu.popoverPresentationController?.sourceRect = sourceView.bounds
        present(menu, animated: true)
    }

    private func updateCameraFormat(_ format: RealtimeVideoFormat) {
        guard connectionState == .ready, cameraFormatTask == nil else { return }
        cameraActionBar.setCameraFormatEnabled(false)
        cameraFormatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                cameraFormatTask = nil
                cameraActionBar.setCameraFormatEnabled(connectionState == .ready)
            }
            do {
                try await realtimeManager.updateCameraFormat(format)
                previewView.updateVideoContentMode()
            } catch {
                guard !Task.isCancelled else { return }
                XLToast.show(error.localizedDescription, in: view)
            }
        }
    }

    private func startLocalMedia() {
        let input = localInput
        let pendingCleanup = mediaCleanupTask
        let pendingRealtimeListener = realtimeListenerTask
        localMediaOperationTask?.cancel()
        localMediaOperationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await pendingCleanup?.value
            await pendingRealtimeListener?.value
            guard !Task.isCancelled else { return }
            do {
                let stream = try await createLocalMediaStream(for: input)
                guard !Task.isCancelled else {
                    await realtimeManager.close()
                    return
                }
                guard displayLocalPreview(stream) else {
                    await realtimeManager.close()
                    return
                }
                cameraActionBar.setSwitchCameraEnabled(localInput == nil)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                presentRealtimeError(XmaxError.from(error))
                loadingOverlay.hideLoading()
            }
        }
    }

    private func createLocalMediaStream(
        for input: RealtimeLocalInput?
    ) async throws -> RealtimeMediaStream {
        switch input {
        case let .image(image):
            return try await realtimeManager.createLocalImageStream(
                image: image
            )
        case let .video(fileURL):
            return try await realtimeManager.createLocalVideoStream(
                fileURL: fileURL
            )
        case let .externalVideo(fileURL):
            let source = try await RealtimeFileVideoSource.make(
                fileURL: fileURL,
                frameRate: realtimeManager.options.model.defaultFrameRate
            )
            let stream = try await realtimeManager.createExternalVideoStream(source: source)
            if source.hasAudio {
                try await realtimeManager.setRemoteAudioVolume(1)
            }
            return stream
        case nil:
            return try await realtimeManager.createLocalCameraStream(
                videoFormat: RealtimePreferences.cameraVideoFormat,
                position: .front,
                useMicrophone: true
            )
        }
    }

    private func displayLocalPreview(
        _ stream: RealtimeMediaStream
    ) -> Bool {
        guard let videoTrack = stream.videoTrack else {
            assertionFailure("Realtime media stream has no video track")
            return false
        }
        localMediaStream = stream
        previewView.displayLocal(videoTrack)
        return true
    }

    private func closeRealtime(
        cancelsReferenceUploads: Bool = true
    ) {
        if recordingButtonState == .recording {
            stopRecordingAndSave()
        } else if recordingButtonState == .preparing {
            recordingOperationTask?.cancel()
            setRecordingButtonState(.idle)
        }
        if cancelsReferenceUploads {
            referenceUploadTasks.values.forEach { $0.cancel() }
            referenceUploadTasks.removeAll()
            referenceUploadRequestIDs.removeAll()
        }

        let previousCleanup = mediaCleanupTask
        let pendingLocalMediaOperation = localMediaOperationTask
        let pendingGenerationOperation = generationOperationTask
        let pendingDisconnect = disconnectTask
        disconnectTask = nil
        generationRequestID = nil
        let pendingRealtimeListener = realtimeListenerTask
        let pendingCameraFormat = cameraFormatTask
        pendingCameraFormat?.cancel()

        pendingLocalMediaOperation?.cancel()
        localMediaOperationTask = nil

        pendingGenerationOperation?.cancel()
        generationOperationTask = nil

        touchAnimationPreparationTask?.cancel()
        touchAnimationPreparationTask = nil

        frameInterpolationTask?.cancel()
        frameInterpolationTask = nil

        audioVolumeStateTask?.cancel()
        audioVolumeStateTask = nil

        pendingRealtimeListener?.cancel()
        realtimeListenerTask = nil

        isGenerationRequested = false
        isTouchAnimationGenerationRequested = false
        selectedReference = nil
        currentGenerationContext = nil
        touchAnimationReferencePath = nil

        localMediaStream = nil
        remoteVideoTrack = nil

        controlPanelView.setGenerationActive(false)
        controlPanelView.clearReferenceSelection()
        cameraActionBar.setSwitchCameraEnabled(false)
        cameraActionBar.setCameraFormatEnabled(false)
        loadingOverlay.hideLoading()
        connectionState = .idle
        controlPanelView.isUserInteractionEnabled = false
        previewView.displayLocal(nil)

        let realtimeManager = realtimeManager
        let statistics = statistics
        statistics.clear()
        mediaCleanupTask = Task {
            await previousCleanup?.value
            await pendingRealtimeListener?.value

            await realtimeManager.setUplinkVideoStatisticsListener(nil)
            await realtimeManager.setDownlinkVideoStatisticsListener(nil)
            await realtimeManager.setNetworkQualityListener(nil)
            statistics.clear()
            await realtimeManager.setStateListener(nil)
            try? await realtimeManager.setRemoteMediaFrameListener(nil)

            await pendingLocalMediaOperation?.value
            await pendingDisconnect?.value
            await pendingGenerationOperation?.value
            await pendingCameraFormat?.value

            await realtimeManager.close()
        }
    }

    func suspendRealtimeForBackground() {
        guard !isSuspendedForBackground else { return }
        isSuspendedForBackground = true
        view.endEditing(true)
        closeRealtime(cancelsReferenceUploads: false)
    }

    func resumeRealtimeAfterBackgroundIfNeeded() {
        guard isSuspendedForBackground,
              UIApplication.shared.applicationState == .active,
              viewIfLoaded?.window != nil else {
            return
        }
        isSuspendedForBackground = false
        controlPanelView.isUserInteractionEnabled = false
        observeRealtimeEvents()
        startLocalMedia()
    }

    private func replaceLocalMedia(with input: RealtimeLocalInput) {
        if recordingButtonState == .recording {
            stopRecordingAndSave()
        }
        let pendingLocalOperation = localMediaOperationTask
        pendingLocalOperation?.cancel()
        let pendingGenerationOperation = generationOperationTask
        pendingGenerationOperation?.cancel()
        generationOperationTask = nil
        generationRequestID = nil
        let pendingDisconnect = disconnectTask
        disconnectTask = nil
        let pendingTouchAnimationPreparation = touchAnimationPreparationTask
        pendingTouchAnimationPreparation?.cancel()
        touchAnimationPreparationTask = nil

        let restartsTouchAnimation = isGenerationRequested
            && isTouchAnimationGenerationRequested
        let restartContext = isGenerationRequested && !restartsTouchAnimation
            ? currentGenerationContext
            : nil
        let selectedReferenceID = selectedReference?.id
        let faceRestoration = selectedReference?.categoryID == "clothx"
        isGenerationRequested = false
        isTouchAnimationGenerationRequested = false
        controlPanelView.setGenerationActive(false)
        currentGenerationContext = nil
        touchAnimationReferencePath = nil
        localMediaStream = nil
        remoteVideoTrack = nil
        previewView.displayLocal(nil)
        controlPanelView.isUserInteractionEnabled = false

        localMediaOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await pendingLocalOperation?.value
            await pendingDisconnect?.value
            await pendingGenerationOperation?.value
            await pendingTouchAnimationPreparation?.value
            guard !Task.isCancelled else { return }

            await realtimeManager.close()
            guard !Task.isCancelled else { return }

            localInput = input
            do {
                let stream = try await createLocalMediaStream(for: input)
                guard !Task.isCancelled else {
                    await realtimeManager.close()
                    return
                }
                guard displayLocalPreview(stream) else {
                    await realtimeManager.close()
                    return
                }

                if restartsTouchAnimation {
                    startTouchAnimationGeneration()
                } else if let restartContext {
                    startGeneration(
                        context: restartContext,
                        selectedReferenceID: selectedReferenceID,
                        faceRestoration: faceRestoration
                    )
                } else {
                    renderPreviewLoadingState()
                }
            } catch {
                guard !Task.isCancelled else { return }
                presentRealtimeError(XmaxError.from(error))
                loadingOverlay.hideLoading()
            }
        }
    }

    private func startGeneration(
        context: RealtimeContext,
        selectedReferenceID: String?,
        faceRestoration: Bool = false,
        isTouchAnimation: Bool = false
    ) {
        if !isTouchAnimation {
            touchAnimationPreparationTask?.cancel()
            touchAnimationPreparationTask = nil
        }
        isGenerationRequested = true
        isTouchAnimationGenerationRequested = isTouchAnimation
        controlPanelView.setGenerationActive(true)
        currentGenerationContext = context
        loadingOverlay.startLoading()
        guard let localMediaStream else {
            isGenerationRequested = false
            isTouchAnimationGenerationRequested = false
            controlPanelView.setGenerationActive(false)
            currentGenerationContext = nil
            renderPreviewLoadingState()
            if let selectedReferenceID {
                controlPanelView.clearReferenceSelection(
                    matching: selectedReferenceID
                )
            }
            XLToast.show(XLLocalization.text("realtime.media.notReady"), in: view)
            return
        }

        let requestID = UUID()
        generationRequestID = requestID
        let pendingDisconnect = disconnectTask
        generationOperationTask = Task { @MainActor [weak self] in
            await pendingDisconnect?.value
            guard let self, generationRequestID == requestID, !Task.isCancelled else { return }
            defer {
                if generationRequestID == requestID {
                    generationRequestID = nil
                    generationOperationTask = nil
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
                previewView.displayRealtime(remoteStream.videoTrack)
                loadingOverlay.hideLoading()
            } catch {
                let resolvedError = XmaxError.from(error)
                guard generationRequestID == requestID, isGenerationRequested,
                      !Task.isCancelled, resolvedError.code != .cancelled else { return }
                let state = await realtimeManager.currentState
                guard generationRequestID == requestID, isGenerationRequested, !Task.isCancelled else { return }
                if state.connectionState == .generating {
                    loadingOverlay.hideLoading()
                    presentRealtimeError(resolvedError)
                    return
                }
                isGenerationRequested = false
                isTouchAnimationGenerationRequested = false
                controlPanelView.setGenerationActive(false)
                if currentGenerationContext == context {
                    currentGenerationContext = nil
                }
                loadingOverlay.hideLoading()
                remoteVideoTrack = nil
                presentRealtimeError(resolvedError)
                if let selectedReferenceID {
                    controlPanelView.clearReferenceSelection(
                        matching: selectedReferenceID
                    )
                }
            }
        }
    }

    private func disconnectGeneration() {
        if recordingButtonState == .recording {
            stopRecordingAndSave()
        }
        touchAnimationPreparationTask?.cancel()
        touchAnimationPreparationTask = nil
        isGenerationRequested = false
        isTouchAnimationGenerationRequested = false
        controlPanelView.setGenerationActive(false)
        currentGenerationContext = nil
        loadingOverlay.hideLoading()
        remoteVideoTrack = nil
        previewView.hideRealtime()
        generationRequestID = nil
        let pendingGeneration = generationOperationTask
        pendingGeneration?.cancel()
        generationOperationTask = nil
        let previousDisconnect = disconnectTask
        let realtimeManager = realtimeManager
        disconnectTask = Task {
            await previousDisconnect?.value
            await realtimeManager.disconnect()
            await pendingGeneration?.value
        }
    }

    @objc func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[
            UIResponder.keyboardFrameEndUserInfoKey
        ] as? CGRect else { return }
        let convertedFrame = view.convert(keyboardFrame, from: nil)
        let keyboardOverlap = max(0, view.bounds.maxY - convertedFrame.minY)
        view.layoutIfNeeded()
        promptKeyboardBottomConstraint?.update(offset: -keyboardOverlap)
        promptKeyboardView.alpha = 1
        animateAlongsideKeyboard(notification) {
            self.view.layoutIfNeeded()
        }
    }

    @objc func keyboardWillHide(_ notification: Notification) {
        view.layoutIfNeeded()
        promptKeyboardBottomConstraint?.update(
            offset: RealtimePromptKeyboardView.preferredHeight
        )
        animateAlongsideKeyboard(notification) {
            self.view.layoutIfNeeded()
        }
    }

    @objc func keyboardDidHide() {
        promptKeyboardView.isHidden = true
        promptKeyboardView.alpha = 0
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func presentLocalMediaPicker() {
        guard let kind = localInput?.kind,
              presentedViewController == nil else {
            return
        }

        view.endEditing(true)
        localMediaPicker.present(
            from: self,
            kind: kind
        ) { [weak self] result in
            guard let self else { return }

            switch result {
            case let .success(.some(input)):
                if localInput?.usesExternalSource == true, case let .video(fileURL) = input {
                    replaceLocalMedia(with: .externalVideo(fileURL))
                } else {
                    replaceLocalMedia(with: input)
                }
            case .success(.none):
                break
            case let .failure(error):
                XLToast.show(error.localizedDescription, in: view)
            }
        }
    }

    private func switchCamera() {
        guard localInput == nil,
              localMediaStream != nil else {
            return
        }

        let retainedRemoteVideoTrack = remoteVideoTrack
        if isGenerationRequested {
            remoteVideoTrack = nil
        }
        cameraActionBar.setSwitchCameraEnabled(false)
        previewView.setCameraSwitchTransitionActive(true)
        localMediaOperationTask?.cancel()
        localMediaOperationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                previewView.setCameraSwitchTransitionActive(false)
                cameraActionBar.setSwitchCameraEnabled(true)
            }
            guard let stream = try? await realtimeManager.switchCamera(),
                  !Task.isCancelled else {
                return
            }
            localMediaStream = stream
            previewView.updateLocal(stream.videoTrack)
            if isGenerationRequested,
               let retainedRemoteVideoTrack {
                remoteVideoTrack = retainedRemoteVideoTrack
                previewView.displayRealtime(retainedRemoteVideoTrack)
                loadingOverlay.hideLoading()
            }
        }
    }

    private func animateAlongsideKeyboard(
        _ notification: Notification,
        animations: @escaping () -> Void
    ) {
        let duration = (notification.userInfo?[
            UIResponder.keyboardAnimationDurationUserInfoKey
        ] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (notification.userInfo?[
            UIResponder.keyboardAnimationCurveUserInfoKey
        ] as? NSNumber)?.uintValue ?? 7
        let options = UIView.AnimationOptions(rawValue: curve << 16)
            .union([.beginFromCurrentState, .allowUserInteraction])
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: options,
            animations: animations
        )
    }

    @objc private func goBack() {
        navigationController?.popViewController(animated: true)
    }
}

private enum RealtimeDemoError: LocalizedError {
    case connectionTransitioning
    case imageEncodingFailed
    case photoLibraryPermissionDenied
    case videoSaveFailed

    var errorDescription: String? {
        switch self {
        case .connectionTransitioning:
            return XLLocalization.text("realtime.connection.busy")
        case .imageEncodingFailed:
            return XLLocalization.text("realtime.image.error")
        case .photoLibraryPermissionDenied:
            return XLLocalization.text("realtime.photos.permission")
        case .videoSaveFailed:
            return XLLocalization.text("realtime.video.save.error")
        }
    }
}
