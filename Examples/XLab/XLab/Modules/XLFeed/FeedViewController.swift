import PhotosUI
import SnapKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XmaxSDK

final class FeedViewController: UIViewController, UIGestureRecognizerDelegate {
    private enum MediaSelectionKind: Sendable {
        case image
        case video
        case externalVideo
        case customTrajectoryImage

        var isVideo: Bool {
            self == .video || self == .externalVideo
        }

        var usesCustomTrajectoryRenderer: Bool {
            self == .customTrajectoryImage
        }
    }

    // 网络与媒体选择状态
    private var networkPreflightTask: URLSessionDataTask?
    private var isPickingMedia = false
    private var pendingMediaSelectionKind: MediaSelectionKind?

    // 首页可见且应用处于前台时刷新当前 API Key 的积分。
    private let creditBalance = FeedCreditBalancePoller()
    private var modelRegistryView: FeedModelRegistryCardView?
    private var isFeedVisible = false
    private var isApplicationActive = UIApplication.shared.applicationState == .active

    // 界面语言
    private var displayedLanguageCode = XLLocalization.languageCode

    // 界面组件
    private lazy var scrollView: UIScrollView = {
        let view = UIScrollView()
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .always
        return view
    }()

    private lazy var contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        return stack
    }()
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    override func loadView() {
        view = FeedGradientView(
            colors: [
                .feed(rgb: 0x0C121B),
                .feed(rgb: 0x070A0F),
                .feed(rgb: 0x090D13)
            ],
            startPoint: CGPoint(x: 0.1, y: 0),
            endPoint: CGPoint(x: 0.9, y: 1)
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        creditBalance.onChange = { [weak self] state in
            self?.modelRegistryView?.displayCreditBalance(state)
        }
        configureBackgroundGlow()
        configureScrollView()
        populateFeed()
        configureKeyboardDismissal()
        performNetworkPreflight()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLanguage),
            name: XLLocalization.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pauseCreditBalance),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshSystemLanguage),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isFeedVisible = true
        refreshCreditBalance()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isFeedVisible = false
        refreshCreditBalance()
    }

    @objc private func pauseCreditBalance() {
        isApplicationActive = false
        refreshCreditBalance()
    }

    private func refreshCreditBalance() {
        creditBalance.update(
            apiKey: UserDefaults.standard.string(forKey: RealtimePreferences.apiKeyStorageKey) ?? "",
            environment: RealtimePreferences.environment,
            isActive: isFeedVisible && isApplicationActive
        )
    }

    @objc private func refreshSystemLanguage() {
        isApplicationActive = true
        refreshCreditBalance()
        guard displayedLanguageCode != XLLocalization.languageCode else { return }
        refreshLanguage()
    }

    @objc private func refreshLanguage() {
        view.endEditing(true)
        let offset = scrollView.contentOffset

        for subview in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        displayedLanguageCode = XLLocalization.languageCode
        populateFeed()
        performNetworkPreflight()
        refreshCreditBalance()

        view.layoutIfNeeded()
        let minimumOffset = -scrollView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: offset.x, y: min(max(offset.y, minimumOffset), maximumOffset)),
            animated: false
        )
    }

    private func configureBackgroundGlow() {
        let blueGlow = makeGlow(color: .feed(rgb: 0x4B7BFF, alpha: 0.14), diameter: 260, blurRadius: 70)
        view.addSubview(blueGlow)
        let mintGlow = makeGlow(color: .feed(rgb: 0x4DF0B5, alpha: 0.12), diameter: 220, blurRadius: 75)
        view.addSubview(mintGlow)

        blueGlow.snp.makeConstraints { make in
            make.size.equalTo(260)
            make.trailing.equalToSuperview().offset(135)
            make.top.equalToSuperview().offset(-55)
        }
        mintGlow.snp.makeConstraints { make in
            make.size.equalTo(220)
            make.leading.equalToSuperview().offset(-145)
            make.top.equalToSuperview().offset(330)
        }
    }

    private func configureScrollView() {
        view.addSubview(scrollView)

        scrollView.addSubview(contentStack)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        contentStack.snp.makeConstraints { make in
            make.leading.equalTo(scrollView.contentLayoutGuide).offset(18)
            make.trailing.equalTo(scrollView.contentLayoutGuide).offset(-18)
            make.top.equalTo(scrollView.contentLayoutGuide).offset(20)
            make.bottom.equalTo(scrollView.contentLayoutGuide).offset(-32)
            make.width.equalTo(scrollView.frameLayoutGuide).offset(-36)
        }
    }

    private func populateFeed() {
        contentStack.addArrangedSubview(makeHeader())
        contentStack.addArrangedSubview(feedFixedSpacer(height: 34))
        contentStack.addArrangedSubview(makeHero())
        contentStack.addArrangedSubview(feedFixedSpacer(height: 12))
        contentStack.addArrangedSubview(makeMetrics())
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))
        let modelRegistry = FeedModelRegistryCardView()
        modelRegistryView = modelRegistry
        modelRegistry.onAPIKeyChange = { [weak self] in self?.refreshCreditBalance() }
        modelRegistry.displayCreditBalance(creditBalance.state)
        contentStack.addArrangedSubview(modelRegistry)
        contentStack.addArrangedSubview(feedFixedSpacer(height: 30))
        contentStack.addArrangedSubview(
            makeSectionHeader(
                title: XLLocalization.text("feed.pipelines"),
                subtitle: XLLocalization.text("feed.input")
            )
        )
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))

        let realtimeCard = FeedPipelineCardView(
            sequence: "01",
            modeID: "MODE_01 / CAMERA",
            statusColor: FeedPalette.mint,
            title: XLLocalization.text("feed.camera.title"),
            subtitle: XLLocalization.text("feed.camera.subtitle"),
            capability: "createLocalCameraStream()"
        )
        realtimeCard.isUserInteractionEnabled = true
        realtimeCard.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(openRealtime))
        )
        contentStack.addArrangedSubview(realtimeCard)
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))
        let videoCard = FeedPipelineCardView(
            sequence: "02",
            modeID: "MODE_02 / VIDEO.FILE",
            statusColor: FeedPalette.blue,
            title: XLLocalization.text("feed.video.title"),
            subtitle: XLLocalization.text("feed.video.subtitle"),
            capability: "createLocalVideoStream()"
        )
        videoCard.isUserInteractionEnabled = true
        videoCard.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(selectLocalVideo))
        )
        contentStack.addArrangedSubview(videoCard)
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))
        let imageCard = FeedPipelineCardView(
            sequence: "03",
            modeID: "MODE_03 / IMAGE.FILE",
            statusColor: FeedPalette.purple,
            title: XLLocalization.text("feed.image.title"),
            subtitle: XLLocalization.text("feed.image.subtitle"),
            capability: "createLocalImageStream()"
        )
        imageCard.isUserInteractionEnabled = true
        imageCard.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(selectLocalImage))
        )
        contentStack.addArrangedSubview(imageCard)

        contentStack.addArrangedSubview(feedFixedSpacer(height: 30))
        contentStack.addArrangedSubview(
            makeSectionHeader(title: XLLocalization.text("feed.features"), subtitle: XLLocalization.text("feed.examples"))
        )
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))
        let swiftUICard = FeedFeatureCardView(
            category: "SDK UI / SWIFTUI",
            watermark: "UI",
            accentColor: FeedPalette.red,
            iconName: "swift",
            iconLabel: "SWIFTUI",
            title: XLLocalization.text("feed.swiftui.title"),
            subtitle: XLLocalization.text("feed.swiftui.subtitle"),
            tags: ["SWIFTUI", "XMAXVIDEO", "REALTIME"],
            highlightedTag: "SWIFTUI"
        )
        swiftUICard.isUserInteractionEnabled = true
        swiftUICard.addGestureRecognizer(
            UITapGestureRecognizer(
                target: self,
                action: #selector(openSwiftUIRealtime)
            )
        )
        contentStack.addArrangedSubview(swiftUICard)
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))
        let externalCaptureCard = FeedFeatureCardView(
            category: "SDK MEDIA / EXTERNAL",
            watermark: "PCM",
            accentColor: FeedPalette.mint,
            iconName: "video",
            iconLabel: "EXTERNAL",
            title: XLLocalization.text("feed.external.title"),
            subtitle: XLLocalization.text("feed.external.subtitle"),
            tags: ["EXTERNAL SOURCE", "VIDEO", "PCM AUDIO"],
            highlightedTag: "EXTERNAL SOURCE"
        )
        externalCaptureCard.isUserInteractionEnabled = true
        externalCaptureCard.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(selectExternalVideo))
        )
        contentStack.addArrangedSubview(externalCaptureCard)
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))
        let customTrajectoryCard = FeedFeatureCardView(
            category: "SDK RENDERING / TRAJECTORY",
            watermark: "FX",
            accentColor: FeedPalette.pink,
            iconName: "sdk_feature_trajectory_custom",
            iconLabel: "RENDER",
            title: XLLocalization.text("feed.render.title"),
            subtitle: XLLocalization.text("feed.render.subtitle"),
            tags: ["CANVAS", "MULTI-TOUCH", "CUSTOM EFFECT"],
            highlightedTag: "CUSTOM EFFECT"
        )
        customTrajectoryCard.isUserInteractionEnabled = true
        customTrajectoryCard.addGestureRecognizer(
            UITapGestureRecognizer(
                target: self,
                action: #selector(selectCustomTrajectoryImage)
            )
        )
        contentStack.addArrangedSubview(customTrajectoryCard)
        contentStack.addArrangedSubview(feedFixedSpacer(height: 14))
        let storageCard = FeedFeatureCardView(
            category: "SDK SERVICE / STORAGE",
            watermark: "URL",
            accentColor: FeedPalette.orange,
            iconName: "sdk_feature_storage",
            iconLabel: "UPLOAD",
            title: XLLocalization.text("feed.storage.title"),
            subtitle: XLLocalization.text("feed.storage.subtitle"),
            tags: ["IMAGE", "VIDEO", "REMOTE URL"],
            highlightedTag: "REMOTE URL"
        )
        storageCard.isUserInteractionEnabled = true
        storageCard.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(openStorage))
        )
        contentStack.addArrangedSubview(storageCard)
        contentStack.addArrangedSubview(feedFixedSpacer(height: 10))
        contentStack.addArrangedSubview(makeFooter())
    }

    private func configureKeyboardDismissal() {
        let tapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(dismissKeyboard)
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)
    }

    private func performNetworkPreflight() {
        networkPreflightTask?.cancel()
        let address = RealtimePreferences.environment == .china
            ? "https://cloud.xmax.22duck.cn/open/api/v1"
            : "https://api.xmax.cloud/open/api/v1"
        guard let url = URL(
            string: address
        ) else {
            return
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 8
        )
        request.httpMethod = "HEAD"
        networkPreflightTask = URLSession.shared.dataTask(with: request)
        networkPreflightTask?.resume()
    }

    @objc private func selectLocalVideo() {
        guard validateAPIKey() else { return }
        presentMediaPicker(for: .video)
    }

    @objc private func selectExternalVideo() {
        guard validateAPIKey() else { return }
        presentMediaPicker(for: .externalVideo)
    }

    @objc private func selectLocalImage() {
        guard validateAPIKey() else { return }
        presentMediaPicker(for: .image)
    }

    @objc private func selectCustomTrajectoryImage() {
        guard validateAPIKey() else { return }
        presentMediaPicker(for: .customTrajectoryImage)
    }

    private func validateAPIKey() -> Bool {
        let apiKey = UserDefaults.standard.string(
            forKey: RealtimePreferences.apiKeyStorageKey
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            XLToast.show(XLLocalization.text("feed.api.required"), in: view)
            return false
        }
        return true
    }

    private func presentMediaPicker(for kind: MediaSelectionKind) {
        guard !isPickingMedia,
              presentedViewController == nil else {
            return
        }

        pendingMediaSelectionKind = kind

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 1
        configuration.filter = kind.isVideo ? .videos : .images
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    private func loadSelectedMedia(
        _ result: PHPickerResult,
        kind: MediaSelectionKind
    ) {
        let provider = result.itemProvider
        let expectedType = kind.isVideo ? UTType.movie : UTType.image
        let registeredType = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first { type in
                kind.isVideo
                    ? type.conforms(to: .movie)
                    : type.conforms(to: .image)
            }
        let typeIdentifier = registeredType?.identifier ?? expectedType.identifier
        let preferredExtension = registeredType?.preferredFilenameExtension

        switch kind {
        case .image, .customTrajectoryImage:
            loadSelectedImage(from: provider, kind: kind)
        case .video, .externalVideo:
            loadSelectedVideo(
                from: provider,
                typeIdentifier: typeIdentifier,
                preferredExtension: preferredExtension,
                kind: kind
            )
        }
    }

    private func loadSelectedImage(
        from provider: NSItemProvider,
        kind: MediaSelectionKind
    ) {
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.finishMediaSelection(error: error, kind: .image)
                }
                return
            }
            guard let image = object as? UIImage else {
                DispatchQueue.main.async {
                    self.finishMediaSelection(
                        error: FeedMediaSelectionError.unreadableFile,
                        kind: .image
                    )
                }
                return
            }

            DispatchQueue.main.async {
                self.finishMediaSelection(
                    with: .image(image),
                    usesCustomTrajectoryRenderer:
                        kind.usesCustomTrajectoryRenderer
                )
            }
        }
    }

    private func loadSelectedVideo(
        from provider: NSItemProvider,
        typeIdentifier: String,
        preferredExtension: String?,
        kind: MediaSelectionKind
    ) {
        provider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { [weak self] sourceURL, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.finishMediaSelection(error: error, kind: kind)
                }
                return
            }
            guard let sourceURL else {
                DispatchQueue.main.async {
                    self.finishMediaSelection(
                        error: FeedMediaSelectionError.unreadableFile,
                        kind: kind
                    )
                }
                return
            }

            do {
                let localURL = try Self.copySelectedVideo(
                    sourceURL,
                    preferredExtension: preferredExtension
                )
                DispatchQueue.main.async {
                    self.finishMediaSelection(
                        with: kind == .externalVideo ? .externalVideo(localURL) : .video(localURL),
                        usesCustomTrajectoryRenderer: false
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishMediaSelection(error: error, kind: kind)
                }
            }
        }
    }

    private nonisolated static func copySelectedVideo(
        _ sourceURL: URL,
        preferredExtension: String?
    ) throws -> URL {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        let directory = cachesDirectory.appendingPathComponent(
            "realtime_input",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var fileExtension = sourceURL.pathExtension
        if fileExtension.isEmpty {
            fileExtension = preferredExtension ?? "mp4"
        }
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func finishMediaSelection(
        with input: RealtimeLocalInput,
        usesCustomTrajectoryRenderer: Bool
    ) {
        isPickingMedia = false
        pendingMediaSelectionKind = nil
        navigationController?.pushViewController(
            RealtimeViewController(
                localInput: input,
                trajectoryStyle: usesCustomTrajectoryRenderer
                    ? .xLabCustom
                    : .sdkDefault
            ),
            animated: true
        )
    }

    private func finishMediaSelection(error: Error, kind: MediaSelectionKind) {
        isPickingMedia = false
        pendingMediaSelectionKind = nil
        let fallback = kind.isVideo
            ? XLLocalization.text("feed.video.error")
            : XLLocalization.text("feed.image.error")
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = UIAlertController(
            title: nil,
            message: message.isEmpty ? fallback : message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: XLLocalization.text("common.ok"), style: .default))
        present(alert, animated: true)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var touchedView = touch.view
        while let currentView = touchedView, currentView !== view {
            if currentView is UIControl {
                return false
            }
            touchedView = currentView.superview
        }
        return true
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func makeHeader() -> UIView {
        let mark = FeedBrandMarkView()
        let name = makeFeedLabel(
            "XMAXSDK",
            size: 15,
            weight: .bold,
            color: .feed(rgb: 0xF2F4F7),
            letterSpacing: 1.8
        )
        let platform = makeFeedLabel(
            "EXAMPLE / IOS",
            size: 8,
            color: .white.withAlphaComponent(0.38),
            letterSpacing: 1
        )
        let brandText = feedVerticalStack([name, platform], spacing: 3)
        let brand = feedHorizontalStack([mark, brandText], spacing: 11)
        let version = FeedPillView(
            text: "v\(XmaxSDKInfo.version)",
            foregroundColor: FeedPalette.mint,
            backgroundColor: FeedPalette.mint.withAlphaComponent(0.086)
        )
        let header = feedHorizontalStack([brand, feedFlexibleSpacer(), version, makeLanguageButton()], spacing: 8)
        header.setCustomSpacing(0, after: version)
        return header
    }

    private func makeLanguageButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = FeedPalette.mint
        button.accessibilityLabel = "语言 / Language"
        button.accessibilityValue = XLLocalization.shared.language.title
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(
            title: "语言 / Language",
            children: XLLanguage.allCases.map { language in
                UIAction(
                    title: language.title,
                    state: language == XLLocalization.shared.language ? .on : .off
                ) { _ in
                    XLLocalization.shared.setLanguage(language)
                }
            }
        )
        button.snp.makeConstraints { make in
            make.size.equalTo(44)
        }
        return button
    }

    private func makeHero() -> UIView {
        let card = FeedCardView(
            colors: [.feed(rgb: 0x141D28, alpha: 0.88), .feed(rgb: 0x0C1118, alpha: 0.82)],
            cornerRadius: 20,
            borderColor: .white.withAlphaComponent(0.12),
            shadowRadius: 24,
            shadowOffset: CGSize(width: 0, height: 10)
        )

        let glow = makeGlow(color: .feed(rgb: 0x6895FF, alpha: 0.08), diameter: 96, blurRadius: 28)
        card.contentView.addSubview(glow)
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = FeedPalette.mint
        line.layer.cornerRadius = 1
        line.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 22, height: 2))
        }
        let eyebrow = makeFeedLabel(
            "XMAX PLAYGROUND",
            size: 9,
            weight: .bold,
            color: FeedPalette.mint,
            letterSpacing: 1.2
        )
        let eyebrowRow = feedHorizontalStack([line, eyebrow], spacing: 7)
        let title = makeFeedLabel(
            XLLocalization.text("feed.hero.title"),
            size: 22,
            weight: .bold,
            color: .feed(rgb: 0xF5F7FB),
            letterSpacing: -0.3
        )
        let subtitle = makeFeedLabel(
            XLLocalization.text("feed.hero.subtitle"),
            size: 11,
            color: .feed(rgb: 0x91A0B2)
        )
        let stack = feedVerticalStack([eyebrowRow, title, subtitle])
        title.numberOfLines = 0
        subtitle.numberOfLines = 0
        stack.setCustomSpacing(18, after: eyebrowRow)
        stack.setCustomSpacing(12, after: title)
        card.contentView.addSubview(stack)

        glow.snp.makeConstraints { make in
            make.size.equalTo(96)
            make.trailing.equalToSuperview().offset(36)
            make.bottom.equalToSuperview().offset(42)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(20)
        }
        return card
    }

    private func makeMetrics() -> UIView {
        let runtime = FeedRuntimeMetricView(label: XLLocalization.text("feed.runtime"), value: "iOS")
        let minimum = FeedRuntimeMetricView(label: XLLocalization.text("feed.os"), value: "15+")
        let latestModel = RealtimePreferences.selectedModel.displayName
        let model = FeedRuntimeMetricView(label: XLLocalization.text("feed.latestModel"), value: latestModel)
        let stack = feedHorizontalStack([runtime, minimum, model], spacing: 8)

        runtime.snp.makeConstraints { make in
            make.width.equalTo(minimum)
        }
        minimum.snp.makeConstraints { make in
            make.width.equalTo(model)
        }
        return stack
    }

    private func makeSectionHeader(title: String, subtitle: String) -> UIView {
        let titleLabel = makeFeedLabel(
            title,
            size: 13,
            weight: .bold,
            color: .feed(rgb: 0xC6D0DD),
            letterSpacing: 1.1
        )
        let subtitleLabel = makeFeedLabel(subtitle, size: 11, color: .feed(rgb: 0x667384))
        titleLabel.numberOfLines = 0
        return feedVerticalStack([titleLabel, subtitleLabel], spacing: 5)
    }

    private func makeFooter() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .white.withAlphaComponent(0.09)
        let copyright = makeFeedLabel(
            "Copyright © 2026 XMAX.AI PTE. LTD. All rights reserved.",
            size: 9,
            color: .white.withAlphaComponent(0.31)
        )
        copyright.textAlignment = .center
        let email = makeFeedLabel(
            "sdk@xmax.ai",
            size: 9,
            color: FeedPalette.mint.withAlphaComponent(0.41),
            letterSpacing: 0.4
        )
        email.textAlignment = .center
        container.addSubview(divider)
        container.addSubview(copyright)
        container.addSubview(email)

        divider.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 36, height: 1))
            make.centerX.top.equalToSuperview()
        }
        copyright.snp.makeConstraints { make in
            make.top.equalTo(divider.snp.bottom).offset(18)
            make.centerX.equalToSuperview()
            make.horizontalEdges.lessThanOrEqualToSuperview()
        }
        email.snp.makeConstraints { make in
            make.top.equalTo(copyright.snp.bottom).offset(7)
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-32)
        }
        return container
    }

    private func makeGlow(color: UIColor, diameter: CGFloat, blurRadius: CGFloat) -> UIView {
        let glow = UIView()
        glow.translatesAutoresizingMaskIntoConstraints = false
        glow.backgroundColor = color
        glow.layer.cornerRadius = diameter / 2
        glow.layer.shadowColor = color.cgColor
        glow.layer.shadowOpacity = 1
        glow.layer.shadowRadius = blurRadius
        glow.layer.shadowOffset = .zero
        return glow
    }

    @objc private func openStorage() {
        guard validateAPIKey() else { return }
        navigationController?.pushViewController(StorageViewController(), animated: true)
    }

    @objc private func openRealtime() {
        guard validateAPIKey() else { return }
        navigationController?.pushViewController(RealtimeViewController(), animated: true)
    }

    @objc private func openSwiftUIRealtime() {
        guard validateAPIKey() else { return }
        let view = RealtimeView { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
        let viewController = UIHostingController(rootView: view)
        viewController.view.backgroundColor = .black
        viewController.overrideUserInterfaceStyle = .dark
        navigationController?.pushViewController(viewController, animated: true)
    }
}

extension FeedViewController: PHPickerViewControllerDelegate,
    UIAdaptivePresentationControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let result = results.first, let kind = pendingMediaSelectionKind else {
            isPickingMedia = false
            pendingMediaSelectionKind = nil
            picker.dismiss(animated: true)
            return
        }
        isPickingMedia = true
        picker.dismiss(animated: true) { [weak self] in
            self?.loadSelectedMedia(result, kind: kind)
        }
    }

    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        isPickingMedia = false
        pendingMediaSelectionKind = nil
    }
}

private enum FeedMediaSelectionError: LocalizedError {
    case unreadableFile

    var errorDescription: String? {
        XLLocalization.text("feed.file.error")
    }
}
