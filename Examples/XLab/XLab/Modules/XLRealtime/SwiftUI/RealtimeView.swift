import Kingfisher
import SwiftUI
import UIKit
import XmaxSDK

/// 使用 SwiftUI 实现的实时生成示例页面。
@MainActor
struct RealtimeView: View {
    private enum ReferencePickerDestination {
        case category(String)
        case prompt
    }

    // 页面操作
    private let onBack: @MainActor () -> Void

    // 应用状态
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var localization = XLLocalization.shared

    // 参考图资源
    @StateObject private var referenceStore = RealtimeReferenceStore()

    // 实时资源
    @StateObject private var realtimeSession = RealtimeSessionController()

    // 页面状态
    @State private var selectedCategoryID: String
    @State private var isReferencePickerPresented = false
    @State private var referencePickerDestination: ReferencePickerDestination?
    @State private var isSuspendedForBackground = false
    @State private var isStatisticsVisible = false
    @State private var prompt = ""
    @FocusState private var isPromptFieldFocused: Bool

    init(onBack: @escaping @MainActor () -> Void) {
        self.onBack = onBack
        _selectedCategoryID = State(
            initialValue: RealtimeCategory.all.first?.id ?? ""
        )
    }

    private var cameraVideoContentMode: VideoContentMode {
        guard let format = realtimeSession.localVideoTrack?.videoFormat else { return .fit }
        let fillsViewport = (format.width == 1920 && format.height == 1080) ||
            (format.width == 1080 && format.height == 1920)
        return fillsViewport ? .fill : .fit
    }

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geometry in
                XmaxRealtimeDualVideo(
                    localTrack: realtimeSession.localVideoTrack,
                    remoteTrack: realtimeSession.remoteVideoTrack,
                    videoContentMode: cameraVideoContentMode
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
            .simultaneousGesture(
                TapGesture().onEnded(dismissPromptKeyboard)
            )

            RealtimeLoadingView(isLoading: realtimeSession.isLoading)
                .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])

            topControls

            if isStatisticsVisible {
                GeometryReader { geometry in
                    RealtimeStatisticsPanel(statistics: realtimeSession.statistics)
                        .frame(width: 184)
                        .frame(maxHeight: max(0, geometry.size.height - 72), alignment: .top)
                        .padding(.leading, 12)
                        .padding(.top, 64)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlPanel
        }
        .overlay {
            if let message = realtimeSession.toastMessage {
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(9)
                    .background(Color(white: 16.0 / 255).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 32)
                    .allowsHitTesting(false)
            }
        }
        .task(id: realtimeSession.toastMessage) {
            guard realtimeSession.toastMessage != nil else { return }
            do {
                try await Task.sleep(nanoseconds: 2000000000)
                realtimeSession.toastMessage = nil
            } catch {}
        }
        .sheet(isPresented: $isReferencePickerPresented) {
            RealtimeReferencePhotoPicker {
                finishReferencePicking($0)
            }
            .ignoresSafeArea()
        }
        .alert(
            XLLocalization.text("common.notice"),
            isPresented: Binding(
                get: {
                    referenceStore.errorMessage != nil
                        || realtimeSession.errorMessage != nil
                },
                set: { isPresented in
                    if !isPresented {
                        referenceStore.clearError()
                        realtimeSession.clearError()
                    }
                }
            )
        ) {
            Button(XLLocalization.text("common.confirm"), role: .cancel) {
                referenceStore.clearError()
                realtimeSession.clearError()
            }
        } message: {
            Text(
                referenceStore.errorMessage
                    ?? realtimeSession.errorMessage
                    ?? ""
            )
        }
        .task {
            realtimeSession.start()
        }
        .onAppear {
            referenceStore.onSelectedContextChanged = { context, faceRestoration in
                if let context {
                    realtimeSession.startGeneration(context: context, faceRestoration: faceRestoration)
                } else {
                    realtimeSession.disconnectGeneration()
                }
            }
        }
        .onDisappear {
            isSuspendedForBackground = false
            dismissPromptKeyboard()
            referenceStore.onSelectedContextChanged = nil
            referenceStore.cancelUploads()
            realtimeSession.close()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
        .onChange(of: realtimeSession.isGenerationRequested) { isRequested in
            if !isRequested {
                referenceStore.clearSelection(notifiesContextChange: false)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .environment(\.locale, localization.locale)
    }
}

private extension RealtimeView {
    var topControls: some View {
        HStack(alignment: .top) {
            Button(action: onBack) {
                Image("realtime_nav_back")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(XLLocalization.text("common.home"))

            Spacer()

            VStack(spacing: 12) {
                RealtimeActionButton(
                    title: XLLocalization.text("realtime.flip"),
                    image: Image("realtime_camera_rotate"),
                    isActive: false,
                    isHorizontallyFlipped:
                        realtimeSession.isBackCameraSelected
                ) {
                    realtimeSession.switchCamera()
                }
                .disabled(
                    !realtimeSession.isMediaReady
                        || realtimeSession.isCameraSwitching
                )

                RealtimeActionButton(
                    title: XLLocalization.text("realtime.interpolation"),
                    image: Image(systemName: "bolt.fill"),
                    isActive:
                        realtimeSession.isFrameInterpolationEnabled
                ) {
                    realtimeSession.setFrameInterpolationEnabled(
                        !realtimeSession.isFrameInterpolationEnabled
                    )
                }
                .accessibilityValue(
                    realtimeSession.isFrameInterpolationEnabled
                        ? XLLocalization.text("common.enabled")
                        : XLLocalization.text("common.disabled")
                )
                .accessibilityLabel(
                    realtimeSession.isFrameInterpolationEnabled
                        ? XLLocalization.text("realtime.interpolation.disable")
                        : XLLocalization.text("realtime.interpolation.enable")
                )

                Menu {
                    ForEach(Array(realtimeSession.supportedCameraFormats.enumerated()), id: \.offset) { _, format in
                        Button {
                            realtimeSession.updateCameraFormat(format)
                        } label: {
                            let current = realtimeSession.localVideoTrack?.videoFormat
                            let title = RealtimePreferences.cameraAspectRatioLabel(for: format)
                            if current?.width == format.width && current?.height == format.height {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "aspectratio")
                            .resizable().scaledToFit().frame(width: 22, height: 22)
                        Text(XLLocalization.text("realtime.camera.format"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .disabled(realtimeSession.connectionState != .ready || realtimeSession.isCameraFormatUpdating)
                .opacity(realtimeSession.connectionState == .ready && !realtimeSession.isCameraFormatUpdating ? 1 : 0.4)

                RealtimeActionButton(
                    title: XLLocalization.text("statistics.title"),
                    image: Image(systemName: "chart.bar.fill"),
                    isActive: isStatisticsVisible,
                    activeColor: .blue
                ) {
                    isStatisticsVisible.toggle()
                }
                .accessibilityValue(
                    XLLocalization.text(isStatisticsVisible ? "common.enabled" : "common.disabled")
                )
            }
            .frame(width: 58, height: 284)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 6)
    }

    var controlPanel: some View {
        VStack(spacing: 4) {
            categoryRow
            selectedCategoryContent
                .frame(height: 50)
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .disabled(!realtimeSession.isMediaReady)
        .opacity(realtimeSession.isMediaReady ? 1 : 0.55)
        .background(
            Color(red: 16 / 255, green: 16 / 255, blue: 16 / 255)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    var categoryRow: some View {
        HStack(spacing: 11) {
            Button {
                referenceStore.clearSelection(
                    notifiesContextChange: false
                )
                realtimeSession.disconnectGeneration()
            } label: {
                Image(systemName: "nosign")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(
                        .white.opacity(
                            realtimeSession.isGenerationRequested
                                ? 1
                                : 0.5
                        )
                    )
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(XLLocalization.text("realtime.generation.stop"))
            .disabled(!realtimeSession.isGenerationRequested)
            .animation(
                .easeInOut(duration: 0.3),
                value: realtimeSession.isGenerationRequested
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(RealtimeCategory.all) { category in
                        Button {
                            selectedCategoryID = category.id
                        } label: {
                            Text(category.name)
                                .font(
                                    .system(
                                        size: 13,
                                        weight: selectedCategoryID == category.id
                                            ? .semibold
                                            : .regular
                                    )
                                )
                                .foregroundStyle(
                                    .white.opacity(
                                        selectedCategoryID == category.id
                                            ? 1
                                            : 0.48
                                    )
                                )
                                .frame(
                                    width: categoryButtonWidth(category.name),
                                    height: 36
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            selectedCategoryID == category.id
                                ? .isSelected
                                : []
                        )
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.leading, 14)
    }

    var selectedCategoryContent: some View {
        ZStack {
            ForEach(RealtimeCategory.all) { category in
                categoryContent(category)
                    .opacity(selectedCategoryID == category.id ? 1 : 0)
                    .allowsHitTesting(selectedCategoryID == category.id)
                    .accessibilityHidden(selectedCategoryID != category.id)
            }
        }
    }

    @ViewBuilder
    func categoryContent(_ category: RealtimeCategory) -> some View {
        switch category.content {
        case let .references(categoryID):
            referenceList(categoryID: categoryID)
        case .instruction:
            Button(XLLocalization.text("realtime.generation.start")) {
                startTouchAnimationGeneration()
            }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(.white.opacity(0.14))
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(.white.opacity(0.19), lineWidth: 1)
                }
                .padding(.horizontal, 14)
        case .prompt:
            HStack(spacing: 0) {
                TextField(XLLocalization.text("realtime.prompt.placeholder"), text: $prompt)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    .focused($isPromptFieldFocused)
                    .font(.system(size: 14))
                    .padding(.leading, 11)
                    .padding(.trailing, 10)

                Button {
                    if referenceStore.handlePromptReferenceAction() {
                        referencePickerDestination = .prompt
                        isReferencePickerPresented = true
                    }
                } label: {
                    RealtimePromptReferenceContent(
                        reference: referenceStore.promptReference
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    referenceStore.promptReference?.uploadState == .uploading
                )
                .accessibilityLabel(promptReferenceAccessibilityLabel)

                Button {
                    submitPrompt()
                } label: {
                    Image("realtime_prompt_submit")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 12)
                        .frame(width: 28, height: 28)
                        .background(
                            Color(red: 1, green: 46 / 255, blue: 136 / 255)
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitPrompt)
                .accessibilityLabel(XLLocalization.text("realtime.prompt.submit"))
                .opacity(canSubmitPrompt ? 1 : 0.2)
                .padding(.leading, 8)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                Color(red: 39 / 255, green: 39 / 255, blue: 40 / 255)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 14)
        }
    }

    func referenceList(categoryID: String) -> some View {
        HStack(spacing: 10) {
            Button {
                referencePickerDestination = .category(categoryID)
                isReferencePickerPresented = true
            } label: {
                Image(
                    XLLocalization.languageCode == "zh-Hans"
                        ? "realtime_add_reference"
                        : "realtime_add_reference_en"
                )
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .background(referenceBackgroundColor)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(XLLocalization.text("realtime.reference.add"))

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(
                            referenceStore.references(for: categoryID),
                            id: \.id
                        ) { reference in
                            referenceButton(reference)
                                .id(reference.id)
                        }
                    }
                    .padding(.trailing, 14)
                }
                .onChange(
                    of: referenceStore.selectedReferenceID
                ) { referenceID in
                    guard let referenceID,
                          referenceStore.references(
                              for: categoryID
                          ).contains(where: { $0.id == referenceID }) else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(referenceID, anchor: .center)
                    }
                }
            }
        }
        .padding(.leading, 14)
    }

    func referenceButton(
        _ reference: RealtimeReferenceCatalog.Item
    ) -> some View {
        RealtimeReferenceButton(
            reference: reference,
            isSelected: referenceStore.selectedReferenceID == reference.id
        ) {
            UISelectionFeedbackGenerator().selectionChanged()
            referenceStore.select(reference)
        }
    }

    func finishReferencePicking(
        _ result: RealtimeReferencePhotoPickerResult
    ) {
        isReferencePickerPresented = false
        defer { referencePickerDestination = nil }

        switch result {
        case let .selected(localURL):
            guard let referencePickerDestination else {
                return
            }
            switch referencePickerDestination {
            case let .category(categoryID):
                referenceStore.addReference(
                    localURL: localURL,
                    categoryID: categoryID
                )
            case .prompt:
                referenceStore.setPromptReference(localURL: localURL)
            }
        case .cancelled:
            return
        case .failed:
            referenceStore.showImportError()
        }
    }

    var referenceBackgroundColor: Color {
        Color(red: 48 / 255, green: 48 / 255, blue: 50 / 255)
    }

    var canSubmitPrompt: Bool {
        let normalizedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let canUseReference = referenceStore.promptReference == nil
            || referenceStore.promptReference?.uploadState == .ready
        return !normalizedPrompt.isEmpty && canUseReference
    }

    var promptReferenceAccessibilityLabel: String {
        guard let reference = referenceStore.promptReference else {
            return XLLocalization.text("realtime.reference.prompt.add")
        }
        return switch reference.uploadState {
        case .ready:
            XLLocalization.text("realtime.reference.prompt.delete")
        case .uploading:
            XLLocalization.text("realtime.reference.prompt.uploading")
        case .failed:
            XLLocalization.text("realtime.reference.prompt.retry")
        }
    }

    func startTouchAnimationGeneration() {
        guard !realtimeSession.isGenerationRequested else { return }
        referenceStore.clearSelection(notifiesContextChange: false)
        realtimeSession.startGeneration(
            context: RealtimeContext(
                prompt: RealtimeCategory.defaultPrompt(for: "mox")
            )
        )
    }

    func submitPrompt() {
        let normalizedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard canSubmitPrompt else { return }

        dismissPromptKeyboard()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        referenceStore.clearSelection(notifiesContextChange: false)
        realtimeSession.startGeneration(
            context: RealtimeContext(
                prompt: normalizedPrompt,
                referencePath: referenceStore.promptReference?.referencePath
            )
        )
    }

    func dismissPromptKeyboard() {
        isPromptFieldFocused = false
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard !isSuspendedForBackground else { return }
            isSuspendedForBackground = true
            dismissPromptKeyboard()
            referenceStore.clearSelection(notifiesContextChange: false)
            realtimeSession.close()
        case .active:
            guard isSuspendedForBackground else { return }
            isSuspendedForBackground = false
            realtimeSession.start()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func categoryButtonWidth(_ title: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let textWidth = (title as NSString).size(
            withAttributes: [.font: font]
        ).width
        return ceil(textWidth) + 10
    }
}

private struct RealtimeLoadingView: UIViewRepresentable {
    let isLoading: Bool

    func makeUIView(context: Context) -> RealtimeLoadingOverlay {
        let view = RealtimeLoadingOverlay()
        render(isLoading, in: view)
        return view
    }

    func updateUIView(
        _ view: RealtimeLoadingOverlay,
        context: Context
    ) {
        render(isLoading, in: view)
    }

    static func dismantleUIView(
        _ view: RealtimeLoadingOverlay,
        coordinator: Void
    ) {
        view.hideLoading()
    }

    private func render(
        _ isLoading: Bool,
        in view: RealtimeLoadingOverlay
    ) {
        if isLoading {
            view.startLoading()
        } else {
            view.hideLoading()
        }
    }
}

private struct RealtimePromptReferenceContent: View {
    let reference: RealtimeReferenceCatalog.Item?

    @ViewBuilder
    var body: some View {
        if let reference {
            RealtimePromptReferenceThumbnail(reference: reference)
        } else {
            Image("realtime_prompt_add")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 12, height: 12)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.12))
                .clipShape(Circle())
        }
    }
}

private struct RealtimePromptReferenceThumbnail: View {
    @ObservedObject var reference: RealtimeReferenceCatalog.Item

    var body: some View {
        ZStack {
            KFImage(reference.iconURL)
                .placeholder {
                    Color.white.opacity(0.12)
                }
                .onFailureView {
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .setProcessor(
                    DownsamplingImageProcessor(
                        size: CGSize(width: 42, height: 42)
                    )
                )
                .scaleFactor(UIScreen.main.scale)
                .fade(duration: 0.2)
                .resizable()
                .scaledToFill()

            uploadStateOverlay
        }
        .frame(width: 28, height: 28)
        .background(.white.opacity(0.12))
        .clipShape(Circle())
    }

    @ViewBuilder
    var uploadStateOverlay: some View {
        switch reference.uploadState {
        case .ready:
            EmptyView()
        case .uploading:
            ZStack {
                Color.black.opacity(0.42)
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
            }
        case .failed:
            ZStack {
                Color.black.opacity(0.42)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct RealtimeReferenceButton: View {
    @ObservedObject var reference: RealtimeReferenceCatalog.Item
    let isSelected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            KFImage(reference.iconURL)
                .placeholder {
                    ProgressView().tint(.white)
                }
                .onFailureView {
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .setProcessor(
                    DownsamplingImageProcessor(
                        size: CGSize(width: 75, height: 75)
                    )
                )
                .scaleFactor(UIScreen.main.scale)
                .cacheOriginalImage()
                .fade(duration: 0.2)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .background(
                    Color(red: 48 / 255, green: 48 / 255, blue: 50 / 255)
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay { uploadStateOverlay }
                .overlay { selectionOverlay }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reference.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    var uploadStateOverlay: some View {
        switch reference.uploadState {
        case .ready:
            EmptyView()
        case .uploading:
            ZStack {
                Color.black.opacity(0.42)
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
            }
        case .failed:
            ZStack {
                Color.black.opacity(0.42)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    var selectionOverlay: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                isSelected
                    ? Color(red: 1, green: 46 / 255, blue: 136 / 255)
                    : .clear,
                lineWidth: 2
            )
    }
}

private struct RealtimeActionButton: View {
    let title: String
    let image: Image
    let isActive: Bool
    var isHorizontallyFlipped = false
    var activeColor: Color = .yellow
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(isActive ? activeColor : Color.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .rotation3DEffect(
                        .degrees(isHorizontallyFlipped ? 180 : 0),
                        axis: (x: 0, y: 1, z: 0)
                    )
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
