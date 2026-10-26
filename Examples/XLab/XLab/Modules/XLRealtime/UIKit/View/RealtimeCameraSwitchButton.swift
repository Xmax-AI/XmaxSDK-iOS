import SnapKit
import UIKit

final class RealtimeCameraActionBar: UIView {

    // 事件监听
    var onToggleStatistics: (() -> Void)?
    var onSwitchCamera: (() -> Void)?
    var onFrameInterpolationChanged: ((Bool) -> Void)?
    var onOpenAudioVolume: ((UIView) -> Void)?
    var onOpenCameraFormat: ((UIView) -> Void)?

    // 运行状态
    private var isFrameInterpolationEnabled = false

    private lazy var cameraFormatButton: RealtimeLabeledActionButton = {
        let button = RealtimeLabeledActionButton(
            title: XLLocalization.text("realtime.camera.format"),
            image: UIImage(systemName: "aspectratio")
        )
        button.isEnabled = false
        button.alpha = 0.4
        button.addTarget(self, action: #selector(openCameraFormat), for: .touchUpInside)
        return button
    }()

    // 界面组件
    private lazy var statisticsButton: RealtimeLabeledActionButton = {
        let button = RealtimeLabeledActionButton(
            title: XLLocalization.text("statistics.title"),
            image: UIImage(systemName: "chart.bar.fill")
        )
        button.accessibilityLabel = XLLocalization.text("statistics.title")
        button.addTarget(self, action: #selector(toggleStatistics), for: .touchUpInside)
        return button
    }()

    private lazy var switchCameraButton: RealtimeLabeledActionButton = {
        let button = RealtimeLabeledActionButton(
            title: XLLocalization.text("realtime.flip"),
            image: UIImage(named: "realtime_camera_rotate")
        )
        button.accessibilityLabel = XLLocalization.text("realtime.flipCamera")
        button.addTarget(
            self,
            action: #selector(switchCamera),
            for: .touchUpInside
        )
        return button
    }()

    private lazy var frameInterpolationButton: RealtimeLabeledActionButton = {
        let image = UIImage(
            systemName: "bolt.fill",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 20,
                weight: .medium
            )
        )
        let button = RealtimeLabeledActionButton(
            title: XLLocalization.text("realtime.interpolation"),
            image: image
        )
        button.setActive(isFrameInterpolationEnabled)
        button.accessibilityLabel = isFrameInterpolationEnabled
            ? XLLocalization.text("realtime.interpolation.disable")
            : XLLocalization.text("realtime.interpolation.enable")
        button.accessibilityValue = isFrameInterpolationEnabled
            ? XLLocalization.text("common.enabled")
            : XLLocalization.text("common.disabled")
        button.addTarget(
            self,
            action: #selector(toggleFrameInterpolation),
            for: .touchUpInside
        )
        return button
    }()

    private lazy var audioVolumeButton: RealtimeLabeledActionButton = {
        let button = RealtimeLabeledActionButton(
            title: XLLocalization.text("realtime.volume"),
            image: UIImage(systemName: "slider.horizontal.3")
        )
        button.accessibilityLabel = XLLocalization.text("realtime.volume.remote.adjust")
        button.addTarget(
            self,
            action: #selector(openAudioVolume),
            for: .touchUpInside
        )
        return button
    }()

    private lazy var stackView: UIStackView = {
        let stackView = UIStackView(
            arrangedSubviews: [
                switchCameraButton,
                cameraFormatButton,
                frameInterpolationButton,
                audioVolumeButton,
                statisticsButton
            ]
        )
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 12
        return stackView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSwitchCameraEnabled(_ isEnabled: Bool) {
        switchCameraButton.isEnabled = isEnabled
    }

    func setCameraFormatEnabled(_ enabled: Bool) {
        cameraFormatButton.isEnabled = enabled
        cameraFormatButton.alpha = enabled ? 1 : 0.4
    }

    @objc private func openCameraFormat() {
        onOpenCameraFormat?(cameraFormatButton)
    }

    func setFrameInterpolationEnabled(_ enabled: Bool) {
        isFrameInterpolationEnabled = enabled
        frameInterpolationButton.setActive(enabled)
        frameInterpolationButton.accessibilityLabel = enabled
            ? XLLocalization.text("realtime.interpolation.disable")
            : XLLocalization.text("realtime.interpolation.enable")
        frameInterpolationButton.accessibilityValue = enabled
            ? XLLocalization.text("common.enabled")
            : XLLocalization.text("common.disabled")
    }

    @objc private func switchCamera() {
        onSwitchCamera?()
    }

    @objc private func toggleFrameInterpolation() {
        onFrameInterpolationChanged?(!isFrameInterpolationEnabled)
    }

    func setStatisticsVisible(_ visible: Bool) {
        statisticsButton.setActive(visible, color: .systemBlue)

        statisticsButton.accessibilityValue = XLLocalization.text(
            visible ? "common.enabled" : "common.disabled"
        )
    }

    @objc private func toggleStatistics() {
        onToggleStatistics?()
    }

    @objc private func openAudioVolume() {
        onOpenAudioVolume?(audioVolumeButton)
    }
}

private final class RealtimeLabeledActionButton: UIControl {
    private let title: String
    private let image: UIImage?

    private lazy var iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.image = image?.withRenderingMode(.alwaysTemplate)
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        configureShadow(for: imageView)
        return imageView
    }()

    private lazy var actionLabel: UILabel = {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        configureShadow(for: label)
        return label
    }()

    init(title: String, image: UIImage?) {
        self.title = title
        self.image = image
        super.init(frame: .zero)

        accessibilityTraits = .button
        addSubview(iconView)
        addSubview(actionLabel)

        iconView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(9)
            make.centerX.equalToSuperview()
            make.size.equalTo(22)
        }
        actionLabel.snp.makeConstraints { make in
            make.top.equalTo(iconView.snp.bottom).offset(5)
            make.centerX.equalToSuperview()
            make.horizontalEdges.equalToSuperview().inset(2)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ isActive: Bool, color: UIColor = .systemYellow) {
        iconView.tintColor = isActive ? color : .white
        if isActive {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }

    private func configureShadow(for view: UIView) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.5
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
    }
}
