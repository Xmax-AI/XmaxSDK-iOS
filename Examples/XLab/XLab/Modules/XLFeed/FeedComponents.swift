import UIKit
import SnapKit
import XmaxSDK

enum FeedPalette {
    static let mint = UIColor.feed(rgb: 0x8EF0C8)
    static let blue = UIColor.feed(rgb: 0x78A9FF)
    static let red = UIColor.feed(rgb: 0xFF6B6B)
    static let purple = UIColor.feed(rgb: 0xC9A3FF)
    static let pink = UIColor.feed(rgb: 0xFF8FD8)
    static let orange = UIColor.feed(rgb: 0xF5B86C)
    static let primaryText = UIColor.feed(rgb: 0xF4F7FB)
    static let secondaryText = UIColor.feed(rgb: 0x8E9AA9)
}

enum FeedTypography {
    static let visualScale: CGFloat = 1.15
}

extension UIColor {
    convenience init(feedRGB value: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func feed(rgb value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(feedRGB: value, alpha: alpha)
    }
}

final class FeedGradientView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    private var gradientLayer: CAGradientLayer {
        layer as! CAGradientLayer
    }

    init(
        colors: [UIColor],
        startPoint: CGPoint = CGPoint(x: 0, y: 0),
        endPoint: CGPoint = CGPoint(x: 1, y: 1)
    ) {
        super.init(frame: .zero)
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class FeedCardView: UIView {
    private let surfaceColors: [UIColor]
    private let cornerRadius: CGFloat

    lazy var contentView = UIView()
    private lazy var surfaceView = FeedGradientView(colors: surfaceColors)

    init(
        colors: [UIColor],
        cornerRadius: CGFloat,
        borderColor: UIColor = .feed(rgb: 0xFFFFFF, alpha: 0.13),
        shadowRadius: CGFloat = 20,
        shadowOffset: CGSize = CGSize(width: 0, height: 9)
    ) {
        surfaceColors = colors
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.52
        layer.shadowRadius = shadowRadius
        layer.shadowOffset = shadowOffset

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.layer.cornerRadius = cornerRadius
        surfaceView.layer.borderWidth = 1
        surfaceView.layer.borderColor = borderColor.cgColor
        surfaceView.clipsToBounds = true
        addSubview(surfaceView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.addSubview(contentView)

        surfaceView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: cornerRadius
        ).cgPath
    }
}

final class FeedPillView: UIView {
    init(
        text: String,
        foregroundColor: UIColor,
        backgroundColor: UIColor,
        borderColor: UIColor = .feed(rgb: 0xFFFFFF, alpha: 0.18),
        fontSize: CGFloat = 9,
        horizontalPadding: CGFloat = 11,
        height: CGFloat = 26,
        letterSpacing: CGFloat = 0.8,
        cornerRadius: CGFloat? = nil
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.backgroundColor = backgroundColor
        layer.cornerRadius = cornerRadius ?? height / 2
        layer.borderWidth = 1
        layer.borderColor = borderColor.cgColor

        let label = makeFeedLabel(
            text,
            size: fontSize,
            weight: .bold,
            color: foregroundColor,
            letterSpacing: letterSpacing
        )
        label.textAlignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)

        snp.makeConstraints { make in
            make.height.equalTo(height)
        }
        label.snp.makeConstraints { make in
            make.horizontalEdges.equalToSuperview().inset(horizontalPadding)
            make.centerY.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class FeedBrandMarkView: UIView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let diamond = FeedGradientView(colors: [FeedPalette.mint, .feed(rgb: 0x6495FF)])
        diamond.translatesAutoresizingMaskIntoConstraints = false
        diamond.layer.cornerRadius = 8
        diamond.transform = CGAffineTransform(rotationAngle: .pi / 4)
        addSubview(diamond)

        let letter = makeFeedLabel("X", size: 12, weight: .bold, color: .feed(rgb: 0x07110D))
        letter.textAlignment = .center
        addSubview(letter)

        snp.makeConstraints { make in
            make.size.equalTo(32)
        }
        diamond.snp.makeConstraints { make in
            make.size.equalTo(25)
            make.center.equalToSuperview()
        }
        letter.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class FeedRuntimeMetricView: UIView {
    init(label: String, value: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .feed(rgb: 0x0E141C, alpha: 0.70)
        layer.cornerRadius = 13
        layer.borderWidth = 1
        layer.borderColor = UIColor.feed(rgb: 0xFFFFFF, alpha: 0.09).cgColor

        let labelView = makeFeedLabel(
            label,
            size: 8,
            weight: .bold,
            color: .feed(rgb: 0xFFFFFF, alpha: 0.38),
            letterSpacing: 1
        )
        let valueView = makeFeedLabel(
            value,
            size: 12,
            weight: .bold,
            color: .feed(rgb: 0xE8EDF5)
        )
        valueView.adjustsFontSizeToFitWidth = true
        valueView.minimumScaleFactor = 0.72

        let stack = UIStackView(arrangedSubviews: [labelView, valueView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 7
        addSubview(stack)

        snp.makeConstraints { make in
            make.height.equalTo(66)
        }
        stack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.trailing.equalToSuperview().inset(10)
            make.centerY.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class FeedModelRegistryCardView: FeedCardView, UITextFieldDelegate {
    private static let apiKeyStorageKey = "xlab.realtime.apiKey"

    // 模型选择
    private var selectedModel = RealtimePreferences.selectedModel
    private var modelRows: [(
        model: RealtimeModel,
        row: UIControl,
        activeIndicator: UIView
    )] = []

    private let rtcProviders = RtcProvider.allCases

    private lazy var rtcSelector: UISegmentedControl = {
        let names = rtcProviders.map { provider in
            switch provider {
            case .agora: "Agora"
            case .trtc: "TRTC"
            }
        }
        let selector = UISegmentedControl(items: names)
        selector.selectedSegmentIndex = rtcProviders.firstIndex(
            of: RealtimePreferences.selectedRtcProvider
        ) ?? 0
        selector.backgroundColor = .feed(rgb: 0x080C12, alpha: 0.40)
        selector.selectedSegmentTintColor = FeedPalette.mint
        selector.setTitleTextAttributes([
            .font: feedFont(ofSize: 11, weight: .bold),
            .foregroundColor: UIColor.feed(rgb: 0xD6DEE9)
        ], for: .normal)
        selector.setTitleTextAttributes([
            .foregroundColor: UIColor.feed(rgb: 0x0D1218)
        ], for: .selected)
        selector.accessibilityLabel = XLLocalization.text("feed.rtc.title")
        selector.accessibilityIdentifier = "feed.rtc.selector"
        selector.addTarget(self, action: #selector(rtcProviderDidChange), for: .valueChanged)
        return selector
    }()

    private lazy var apiKeyTextField: UITextField = {
        let textField = UITextField()
        textField.attributedPlaceholder = NSAttributedString(
            string: XLLocalization.text("feed.api.placeholder"),
            attributes: [
                .font: feedFont(ofSize: 10),
                .foregroundColor: UIColor.feed(rgb: 0x607080, alpha: 0.50)
            ]
        )
        textField.text = UserDefaults.standard.string(forKey: Self.apiKeyStorageKey)
        textField.textColor = .feed(rgb: 0xD6DEE9)
        textField.font = feedFont(ofSize: 10)
        textField.isSecureTextEntry = true
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.returnKeyType = .done
        textField.delegate = self
        textField.addTarget(self, action: #selector(apiKeyDidChange), for: .editingChanged)
        return textField
    }()

    private lazy var visibilityButton: UIButton = {
        let button = UIButton(type: .custom)
        button.setImage(UIImage(named: "api_key_visible"), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.alpha = 0.78
        button.accessibilityLabel = XLLocalization.text("feed.api.show")
        button.addTarget(self, action: #selector(toggleApiKeyVisibility), for: .touchUpInside)
        return button
    }()

    init() {
        let models = RealtimePreferences.availableModels

        super.init(
            colors: [.feed(rgb: 0x121B19, alpha: 0.91), .feed(rgb: 0x0D1218, alpha: 0.91)],
            cornerRadius: 17,
            borderColor: .feed(rgb: 0x8EF0C8, alpha: 0.15),
            shadowRadius: 18,
            shadowOffset: CGSize(width: 0, height: 8)
        )

        let title = makeFeedLabel(XLLocalization.text("feed.model.title"), size: 13, weight: .bold, color: .feed(rgb: 0xE9EDF3))
        let modelCount = makeFeedLabel(
            XLLocalization.format("feed.model.count", models.count),
            size: 8,
            color: .feed(rgb: 0xFFFFFF, alpha: 0.44),
            letterSpacing: 0.8
        )
        let header = feedHorizontalStack([title, feedFlexibleSpacer(), modelCount])

        let apiContainer = UIView()
        apiContainer.translatesAutoresizingMaskIntoConstraints = false
        apiContainer.backgroundColor = .feed(rgb: 0x080C12, alpha: 0.26)
        apiContainer.layer.cornerRadius = 12
        apiContainer.layer.borderWidth = 1
        apiContainer.layer.borderColor = UIColor.feed(rgb: 0xFFFFFF, alpha: 0.07).cgColor

        let apiLabel = makeFeedLabel(
            "API KEY",
            size: 8,
            weight: .bold,
            color: .feed(rgb: 0x7E8A9A),
            letterSpacing: 0.9
        )
        let passwordField = UIView()
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.backgroundColor = .feed(rgb: 0x080C12, alpha: 0.40)
        passwordField.layer.cornerRadius = 10
        passwordField.layer.borderWidth = 1
        passwordField.layer.borderColor = UIColor.feed(rgb: 0xFFFFFF, alpha: 0.11).cgColor

        passwordField.addSubview(apiKeyTextField)
        passwordField.addSubview(visibilityButton)

        let prompt = makeFeedLabel(XLLocalization.text("feed.api.prompt"), size: 9, color: .feed(rgb: 0x708090, alpha: 0.60))
        let link = UIButton(type: .custom)
        link.setTitle(XLLocalization.text("feed.api.link"), for: .normal)
        link.setTitleColor(
            FeedPalette.mint.withAlphaComponent(0.63),
            for: .normal
        )
        link.titleLabel?.font = .systemFont(
            ofSize: 9 * FeedTypography.visualScale
        )
        link.addTarget(
            self,
            action: #selector(openApiKeyApplicationPage),
            for: .touchUpInside
        )
        let helpRow = feedHorizontalStack([prompt, link], spacing: 4)
        helpRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        apiContainer.addSubview(apiLabel)
        apiContainer.addSubview(passwordField)
        apiContainer.addSubview(helpRow)

        passwordField.snp.makeConstraints { make in
            make.height.equalTo(40)
            make.horizontalEdges.equalToSuperview().inset(10)
            make.top.equalTo(apiLabel.snp.bottom).offset(8)
        }
        apiKeyTextField.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.verticalEdges.equalToSuperview()
            make.trailing.equalTo(visibilityButton.snp.leading).offset(-8)
        }
        visibilityButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(20)
        }
        apiLabel.snp.makeConstraints { make in
            make.leading.top.equalToSuperview().offset(10)
            make.trailing.lessThanOrEqualToSuperview().inset(10)
        }
        helpRow.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.trailing.lessThanOrEqualToSuperview().inset(10)
            make.top.equalTo(passwordField.snp.bottom).offset(7)
            make.bottom.equalToSuperview().inset(11)
        }

        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .feed(rgb: 0xFFFFFF, alpha: 0.09)
        divider.snp.makeConstraints { make in
            make.height.equalTo(1)
        }

        let modelList = feedVerticalStack(
            models.map(makeModelRow),
            spacing: 4
        )
        updateModelSelection()

        let rtcTitle = makeFeedLabel(
            XLLocalization.text("feed.rtc.title"),
            size: 13,
            weight: .bold,
            color: .feed(rgb: 0xE9EDF3)
        )
        let rtcSelection = feedVerticalStack([rtcTitle, rtcSelector], spacing: 10)
        rtcSelector.snp.makeConstraints { make in
            make.height.equalTo(40)
        }

        let stack = feedVerticalStack([header, apiContainer, divider, modelList, rtcSelection])
        stack.setCustomSpacing(14, after: header)
        stack.setCustomSpacing(12, after: apiContainer)
        stack.setCustomSpacing(4, after: divider)
        stack.setCustomSpacing(16, after: modelList)
        contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(18)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeModelRow(for model: RealtimeModel) -> UIView {
        let diamond = makeFeedLabel("◆", size: 7, color: FeedPalette.mint)
        let modelName = makeFeedLabel(
            model.displayName,
            size: 13,
            weight: .bold,
            color: .feed(rgb: 0xF0F2F5)
        )
        let caseName = model.rawValue
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        let modelIdentifier = makeFeedLabel(
            "RealtimeModel.\(caseName)",
            size: 8,
            color: .feed(rgb: 0xFFFFFF, alpha: 0.44)
        )
        let modelText = feedVerticalStack([modelName, modelIdentifier], spacing: 3)
        let active = FeedPillView(
            text: XLLocalization.text("feed.selected"),
            foregroundColor: FeedPalette.mint,
            backgroundColor: FeedPalette.mint.withAlphaComponent(0.086)
        )
        let content = feedHorizontalStack(
            [diamond, modelText, feedFlexibleSpacer(), active],
            spacing: 10
        )
        content.isUserInteractionEnabled = false
        let row = UIControl()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.backgroundColor = FeedPalette.mint.withAlphaComponent(0.063)
        row.layer.cornerRadius = 10
        row.addSubview(content)
        row.addAction(
            UIAction { [weak self] _ in
                self?.selectModel(model)
            },
            for: .touchUpInside
        )
        row.snp.makeConstraints { make in
            make.height.equalTo(56)
        }
        content.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.trailing.equalToSuperview().inset(8)
            make.verticalEdges.equalToSuperview()
        }
        modelRows.append((model, row, active))
        return row
    }

    private func selectModel(_ model: RealtimeModel) {
        guard model != selectedModel else { return }
        selectedModel = model
        RealtimePreferences.selectedModel = model
        updateModelSelection()
    }

    @objc private func rtcProviderDidChange() {
        let index = rtcSelector.selectedSegmentIndex
        guard rtcProviders.indices.contains(index) else { return }
        RealtimePreferences.selectedRtcProvider = rtcProviders[index]
    }

    private func updateModelSelection() {
        for modelRow in modelRows {
            let isSelected = modelRow.model == selectedModel
            modelRow.activeIndicator.isHidden = !isSelected
            modelRow.row.backgroundColor = isSelected
                ? FeedPalette.mint.withAlphaComponent(0.063)
                : UIColor.feed(rgb: 0xFFFFFF, alpha: 0.025)
            modelRow.row.layer.borderWidth = isSelected ? 1 : 0
            modelRow.row.layer.borderColor = FeedPalette.mint
                .withAlphaComponent(0.16)
                .cgColor
            modelRow.row.accessibilityTraits = isSelected
                ? [.button, .selected]
                : .button
            modelRow.row.accessibilityLabel = modelRow.model.rawValue
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func apiKeyDidChange() {
        UserDefaults.standard.set(
            apiKeyTextField.text ?? "",
            forKey: Self.apiKeyStorageKey
        )
    }

    @objc private func toggleApiKeyVisibility() {
        apiKeyTextField.isSecureTextEntry.toggle()
        let isSecure = apiKeyTextField.isSecureTextEntry
        visibilityButton.setImage(
            UIImage(
                named: isSecure
                    ? "api_key_visible"
                    : "api_key_hidden"
            ),
            for: .normal
        )
        visibilityButton.accessibilityLabel = isSecure
            ? XLLocalization.text("feed.api.show")
            : XLLocalization.text("feed.api.hide")
    }

    @objc private func openApiKeyApplicationPage() {
        let address = RealtimePreferences.environment == .china
            ? "https://platform.xmaxai.com/api-keys"
            : "https://platform.xmax.ai/api-keys"
        guard let url = URL(
            string: address
        ) else {
            return
        }
        UIApplication.shared.open(url)
    }
}

final class FeedPipelineCardView: FeedCardView {
    init(
        sequence: String,
        modeID: String,
        statusColor: UIColor,
        title: String,
        subtitle: String,
        capability: String
    ) {
        super.init(
            colors: [.feed(rgb: 0x141B25, alpha: 0.94), .feed(rgb: 0x0C1118, alpha: 0.94)],
            cornerRadius: 18
        )

        let glow = UIView()
        glow.translatesAutoresizingMaskIntoConstraints = false
        glow.backgroundColor = statusColor.withAlphaComponent(0.10)
        glow.layer.cornerRadius = 56
        contentView.addSubview(glow)

        let stripe = UIView()
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.backgroundColor = statusColor
        stripe.layer.cornerRadius = 1.5
        contentView.addSubview(stripe)

        let sequenceLabel = makeFeedLabel(
            sequence,
            size: 54,
            weight: .bold,
            color: .white.withAlphaComponent(0.032)
        )
        contentView.addSubview(sequenceLabel)

        let modeDot = feedDot(color: statusColor, size: 7, glows: true)
        let mode = makeFeedLabel(
            modeID,
            size: 9,
            weight: .bold,
            color: .feed(rgb: 0x9AA7B7),
            letterSpacing: 0.8
        )
        let modeRow = feedHorizontalStack([modeDot, mode], spacing: 8)

        let statusDot = makeFeedLabel("●", size: 7, color: statusColor)
        let status = makeFeedLabel(XLLocalization.text("feed.ready"), size: 9, weight: .bold, color: statusColor, letterSpacing: 0.8)
        let statusPill = feedPillContainer(
            content: feedHorizontalStack([statusDot, status], spacing: 6),
            height: 25,
            horizontalPadding: 9
        )
        let header = feedHorizontalStack([modeRow, feedFlexibleSpacer(), statusPill])

        let titleLabel = makeFeedLabel(title, size: 19, weight: .bold, color: FeedPalette.primaryText)
        titleLabel.numberOfLines = 0
        let subtitleLabel = makeFeedLabel(subtitle, size: 11, color: FeedPalette.secondaryText)
        subtitleLabel.numberOfLines = 0
        subtitleLabel.attributedText = feedAttributedText(
            subtitle,
            font: subtitleLabel.font,
            color: subtitleLabel.textColor,
            lineHeight: 18
        )

        let capabilityLabel = makeFeedLabel(
            capability,
            size: 9,
            weight: .medium,
            color: .feed(rgb: 0xB8C3D1)
        )
        capabilityLabel.adjustsFontSizeToFitWidth = true
        capabilityLabel.minimumScaleFactor = 0.78
        let capabilityView = UIView()
        capabilityView.translatesAutoresizingMaskIntoConstraints = false
        capabilityView.backgroundColor = .feed(rgb: 0x080C12, alpha: 0.40)
        capabilityView.layer.cornerRadius = 10
        capabilityView.layer.borderWidth = 1
        capabilityView.layer.borderColor = UIColor.feed(rgb: 0xFFFFFF, alpha: 0.086).cgColor
        capabilityView.addSubview(capabilityLabel)

        let runLabel = makeFeedLabel(XLLocalization.text("feed.run"), size: 11, weight: .bold, color: .feed(rgb: 0x08110E))
        runLabel.textAlignment = .center
        let runView = UIView()
        runView.translatesAutoresizingMaskIntoConstraints = false
        runView.backgroundColor = statusColor
        runView.layer.cornerRadius = 10
        runView.layer.shadowColor = UIColor.black.cgColor
        runView.layer.shadowOpacity = 0.25
        runView.layer.shadowRadius = 10
        runView.layer.shadowOffset = CGSize(width: 0, height: 4)
        runView.addSubview(runLabel)

        let actionRow = feedHorizontalStack([capabilityView, runView], spacing: 10)
        capabilityView.snp.makeConstraints { make in
            make.height.equalTo(36)
        }
        capabilityLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(11)
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
        }
        runView.snp.makeConstraints { make in
            make.width.equalTo(82)
            make.height.equalTo(36)
        }
        runLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        let body = feedVerticalStack([header, titleLabel, subtitleLabel, actionRow])
        body.setCustomSpacing(17, after: header)
        body.setCustomSpacing(7, after: titleLabel)
        body.setCustomSpacing(18, after: subtitleLabel)
        contentView.addSubview(body)

        glow.snp.makeConstraints { make in
            make.size.equalTo(112)
            make.trailing.equalToSuperview().offset(38)
            make.top.equalToSuperview().offset(-46)
        }
        stripe.snp.makeConstraints { make in
            make.width.equalTo(3)
            make.height.equalTo(70)
            make.leading.equalToSuperview()
            make.top.equalToSuperview().offset(22)
        }
        sequenceLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(17)
            make.top.equalToSuperview().offset(5)
        }
        body.snp.makeConstraints { make in
            make.horizontalEdges.equalToSuperview().inset(18)
            make.top.equalToSuperview().offset(17)
            make.bottom.equalToSuperview().inset(17)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class FeedFeatureCardView: FeedCardView {
    init(
        category: String,
        watermark: String,
        accentColor: UIColor,
        iconName: String,
        iconLabel: String,
        title: String,
        subtitle: String,
        tags: [String],
        highlightedTag: String
    ) {
        super.init(
            colors: [
                .feed(rgb: 0x1C1813, alpha: 0.94),
                .feed(rgb: 0x0D1117, alpha: 0.94),
                .feed(rgb: 0x151210, alpha: 0.94)
            ],
            cornerRadius: 18
        )

        let glow = UIView()
        glow.translatesAutoresizingMaskIntoConstraints = false
        glow.backgroundColor = accentColor.withAlphaComponent(0.09)
        glow.layer.cornerRadius = 63
        contentView.addSubview(glow)

        let watermarkLabel = makeFeedLabel(
            watermark,
            size: 45,
            weight: .bold,
            color: .white.withAlphaComponent(0.032),
            letterSpacing: -2
        )
        contentView.addSubview(watermarkLabel)

        let stripe = UIView()
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.backgroundColor = accentColor
        stripe.layer.cornerRadius = 1.5
        contentView.addSubview(stripe)

        let categoryDot = feedDot(color: accentColor, size: 7, glows: true)
        let categoryLabel = makeFeedLabel(
            category,
            size: 9,
            weight: .bold,
            color: .feed(rgb: 0xA99A8A),
            letterSpacing: 0.8
        )
        let categoryRow = feedHorizontalStack([categoryDot, categoryLabel], spacing: 8)
        let available = FeedPillView(
            text: XLLocalization.text("feed.available"),
            foregroundColor: accentColor,
            backgroundColor: .white.withAlphaComponent(0.047),
            fontSize: 8,
            horizontalPadding: 10,
            height: 25,
            letterSpacing: 0.7
        )
        let header = feedHorizontalStack([categoryRow, feedFlexibleSpacer(), available])

        let iconTile = FeedGradientView(colors: [
            accentColor.withAlphaComponent(0.28),
            .feed(rgb: 0x1B1712, alpha: 0.28)
        ])
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        iconTile.layer.cornerRadius = 14
        iconTile.layer.borderWidth = 1
        iconTile.layer.borderColor = accentColor.withAlphaComponent(0.28).cgColor
        let iconImage = UIImage(named: iconName)
            ?? UIImage(systemName: iconName)?.withRenderingMode(.alwaysTemplate)
        let icon = UIImageView(image: iconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.tintColor = accentColor
        let iconCaption = makeFeedLabel(iconLabel, size: 6, weight: .bold, color: accentColor, letterSpacing: 0.5)
        iconCaption.textAlignment = .center
        iconTile.addSubview(icon)
        iconTile.addSubview(iconCaption)

        let titleLabel = makeFeedLabel(title, size: 17, weight: .bold, color: FeedPalette.primaryText)
        titleLabel.numberOfLines = 0
        let subtitleLabel = makeFeedLabel(subtitle, size: 9.5, color: .feed(rgb: 0x81786F))
        subtitleLabel.numberOfLines = 0
        let textStack = feedVerticalStack([titleLabel, subtitleLabel], spacing: 5)

        let enterLabel = makeFeedLabel(XLLocalization.text("feed.open"), size: 11, weight: .bold, color: .feed(rgb: 0x08110E))
        enterLabel.textAlignment = .center
        let enterView = UIView()
        enterView.translatesAutoresizingMaskIntoConstraints = false
        enterView.backgroundColor = accentColor
        enterView.layer.cornerRadius = 10
        enterView.addSubview(enterLabel)

        let middle = feedHorizontalStack([iconTile, textStack, enterView], spacing: 13)
        middle.setCustomSpacing(10, after: textStack)

        let tagViews = tags.map { tag -> UIView in
            let label = makeFeedLabel(
                tag,
                size: 7,
                weight: .bold,
                color: tag == highlightedTag ? accentColor : .feed(rgb: 0xA89A8B)
            )
            return feedPillContainer(
                content: label,
                height: 24,
                horizontalPadding: 9,
                cornerRadius: 8,
                backgroundColor: tag == highlightedTag
                    ? .white.withAlphaComponent(0.07)
                    : .feed(rgb: 0x080C12, alpha: 0.40)
            )
        }
        let tagsSpacer = feedFlexibleSpacer()
        let tagsRow = feedHorizontalStack(tagViews + [tagsSpacer], spacing: 7)
        if let lastTagView = tagViews.last {
            tagsRow.setCustomSpacing(0, after: lastTagView)
        }

        let body = feedVerticalStack([header, middle, tagsRow])
        body.setCustomSpacing(15, after: header)
        body.setCustomSpacing(14, after: middle)
        contentView.addSubview(body)

        glow.snp.makeConstraints { make in
            make.size.equalTo(126)
            make.trailing.equalToSuperview().offset(40)
            make.top.equalToSuperview().offset(-52)
        }
        watermarkLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(9)
        }
        stripe.snp.makeConstraints { make in
            make.width.equalTo(3)
            make.height.equalTo(54)
            make.leading.equalToSuperview()
            make.top.equalToSuperview().offset(47)
        }
        iconTile.snp.makeConstraints { make in
            make.size.equalTo(48)
        }
        icon.snp.makeConstraints { make in
            make.width.equalTo(24)
            make.height.equalTo(22)
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(7)
        }
        iconCaption.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(icon.snp.bottom).offset(1)
        }
        enterView.snp.makeConstraints { make in
            make.width.equalTo(58)
            make.height.equalTo(34)
        }
        enterLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        body.snp.makeConstraints { make in
            make.horizontalEdges.equalToSuperview().inset(18)
            make.verticalEdges.equalToSuperview().inset(16)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
func feedFont(
    ofSize size: CGFloat,
    weight: UIFont.Weight = .regular
) -> UIFont {
    .systemFont(ofSize: size * FeedTypography.visualScale, weight: weight)
}

@MainActor
func makeFeedLabel(
    _ text: String,
    size: CGFloat,
    weight: UIFont.Weight = .regular,
    color: UIColor,
    letterSpacing: CGFloat? = nil
) -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = feedFont(ofSize: size, weight: weight)
    label.textColor = color
    if let letterSpacing {
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: label.font as Any,
                .foregroundColor: color,
                .kern: letterSpacing
            ]
        )
    } else {
        label.text = text
    }
    return label
}

@MainActor
func feedAttributedText(
    _ text: String,
    font: UIFont,
    color: UIColor,
    lineHeight: CGFloat
) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    return NSAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    )
}

@MainActor
func feedHorizontalStack(_ views: [UIView], spacing: CGFloat = 0) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = spacing
    return stack
}

@MainActor
func feedVerticalStack(_ views: [UIView], spacing: CGFloat = 0) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = spacing
    return stack
}

@MainActor
func feedFlexibleSpacer() -> UIView {
    let spacer = UIView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
}

@MainActor
func feedFixedSpacer(height: CGFloat) -> UIView {
    let spacer = UIView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.snp.makeConstraints { make in
        make.height.equalTo(height)
    }
    return spacer
}

@MainActor
func feedDot(color: UIColor, size: CGFloat, glows: Bool) -> UIView {
    let dot = UIView()
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.backgroundColor = color
    dot.layer.cornerRadius = size / 2
    if glows {
        dot.layer.shadowColor = color.cgColor
        dot.layer.shadowOpacity = 0.8
        dot.layer.shadowRadius = 7
    }
    dot.snp.makeConstraints { make in
        make.size.equalTo(size)
    }
    return dot
}

@MainActor
func feedPillContainer(
    content: UIView,
    height: CGFloat,
    horizontalPadding: CGFloat,
    cornerRadius: CGFloat? = nil,
    backgroundColor: UIColor = .white.withAlphaComponent(0.047)
) -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = backgroundColor
    container.layer.cornerRadius = cornerRadius ?? height / 2
    container.layer.borderWidth = 1
    container.layer.borderColor = UIColor.feed(rgb: 0xFFFFFF, alpha: 0.09).cgColor
    container.setContentHuggingPriority(.required, for: .horizontal)
    container.setContentCompressionResistancePriority(.required, for: .horizontal)
    content.setContentHuggingPriority(.required, for: .horizontal)
    content.setContentCompressionResistancePriority(.required, for: .horizontal)
    container.addSubview(content)
    container.snp.makeConstraints { make in
        make.height.equalTo(height)
    }
    content.snp.makeConstraints { make in
        make.horizontalEdges.equalToSuperview().inset(horizontalPadding)
        make.centerY.equalToSuperview()
    }
    return container
}
