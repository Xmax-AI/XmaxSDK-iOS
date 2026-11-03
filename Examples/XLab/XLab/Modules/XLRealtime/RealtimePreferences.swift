import Foundation
import XmaxSDK

enum RealtimePreferences {
    /// 从本地缓存读取 XLab API Key 使用的键。
    static let apiKeyStorageKey = "xlab.realtime.apiKey"

    /// 从本地缓存读取所选实时模型使用的键。
    private static let modelStorageKey = "xlab.realtime.model"

    /// XLab 按界面语言选择服务环境：中文使用国内环境，英文使用海外环境。
    static var environment: XmaxEnvironment {
        XLLocalization.languageCode == "zh-Hans" ? .china : .global
    }

    /// XLab 可选择的实时模型。
    static var availableModels: [RealtimeModel] {
        RealtimeModel.allCases
    }

    /// XLab 当前选择的实时生成模型。
    static var selectedModel: RealtimeModel {
        get {
            let models = availableModels
            guard let rawValue = UserDefaults.standard.string(
                forKey: modelStorageKey
            ), let model = RealtimeModel(rawValue: rawValue), models.contains(model) else {
                return models[0]
            }
            return model
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue,
                forKey: modelStorageKey
            )
        }
    }

    /// 摄像头采集使用的视频规格。
    static var cameraVideoFormat: RealtimeVideoFormat {
        selectedModel.defaultCameraVideoFormat
    }

    /// 将摄像头规格显示为最简宽高比。
    static func cameraAspectRatioLabel(for format: RealtimeVideoFormat) -> String {
        var divisor = format.width
        var remainder = format.height
        while remainder != 0 {
            (divisor, remainder) = (remainder, divisor % remainder)
        }
        divisor = max(divisor, 1)
        return "\(format.width / divisor):\(format.height / divisor)"
    }
}
