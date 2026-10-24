/// 实时页面共用的生成分类。
struct RealtimeCategory: Identifiable, Sendable {
    enum Content: Sendable {
        case references(categoryID: String)
        case instruction
        case prompt
    }

    let id: String
    let content: Content

    /// 分类默认提示词，自由模式使用用户输入。
    let defaultPrompt: String

    /// 当前界面语言下的分类名称。
    var name: String {
        XLLocalization.text("category.\(id)")
    }

    static let all = [
        RealtimeCategory(
            id: "charx",
            content: .references(categoryID: "charx"),
            defaultPrompt: "视频中角色替换成参考图中角色"
        ),
        RealtimeCategory(
            id: "clothx",
            content: .references(categoryID: "clothx"),
            defaultPrompt: "视频中人物衣服替换成参考图中衣服"
        ),
        RealtimeCategory(
            id: "vibex",
            content: .references(categoryID: "vibex"),
            defaultPrompt: "视频风格变为参考图指定的风格"
        ),
        RealtimeCategory(
            id: "dimx",
            content: .references(categoryID: "dimx"),
            defaultPrompt: "指定角色在场景中互动"
        ),
        RealtimeCategory(
            id: "mox",
            content: .instruction,
            defaultPrompt: ""
        ),
        RealtimeCategory(
            id: "free",
            content: .prompt,
            defaultPrompt: ""
        ),
    ]

    /// 获取分类的默认提示词。
    ///
    /// - Parameter categoryID: 分类标识。
    /// - Returns: 分类默认提示词，分类不存在时返回空字符串。
    static func defaultPrompt(for categoryID: String) -> String {
        all.first { $0.id == categoryID }?.defaultPrompt ?? ""
    }
}
