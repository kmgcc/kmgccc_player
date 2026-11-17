import Foundation
import SwiftUI

/// A destination always leads to the existing settings view and its real controls.
nonisolated struct SettingsSearchEntry: Identifiable {
    let title: String
    let category: SettingsCategory
    let tab: Int?
    let tabTitle: String?
    let anchor: String?
    private let identity: String?
    private let titleKeys: [String]
    private let contextKeys: [String]

    var id: String { "\(category.rawValue):\(tab ?? -1):\(anchor ?? "top"):\(title):\(identity ?? "")" }

    init(_ title: String, category: SettingsCategory, tab: Int? = nil, tabTitle: String? = nil,
         anchor: String? = nil, keywords: String = "", identity: String? = nil) {
        self.title = title
        self.category = category
        self.tab = tab
        self.tabTitle = tabTitle
        self.anchor = anchor
        self.identity = identity
        titleKeys = SettingsSearchIndex.keys(for: title)
        let path = [category.searchTitle, tabTitle, title].compactMap { $0 }.joined(separator: " ")
        contextKeys = SettingsSearchIndex.keys(for: path) + SettingsSearchIndex.keys(for: keywords)
    }

    fileprivate func rank(query: String, parts: [String]) -> Int? {
        func best(_ value: String) -> Int? {
            let titleRank = titleKeys.compactMap { SettingsSearchIndex.matchRank(value, in: $0) }.min()
            let contextRank = contextKeys.compactMap { SettingsSearchIndex.matchRank(value, in: $0) }.min()
            return [titleRank, contextRank.map { $0 + 2 }].compactMap { $0 }.min()
        }

        let wholeRank = best(query)
        guard parts.count > 1 else { return wholeRank }
        let partRanks = parts.compactMap(best)
        guard partRanks.count == parts.count, let worst = partRanks.max() else { return wholeRank }
        return min(wholeRank ?? (worst + 1), worst + 1)
    }
}

struct SettingsSearchRequest: Equatable {
    let id = UUID()
    let category: SettingsCategory
    let tab: Int?
    let anchor: String?
}

private struct SettingsSearchRequestKey: EnvironmentKey {
    static let defaultValue: SettingsSearchRequest? = nil
}

struct SettingsSearchAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: SettingsSearchRequest? { nil }

    static func reduce(value: inout SettingsSearchRequest?, nextValue: () -> SettingsSearchRequest?) {
        if let next = nextValue() { value = next }
    }
}

extension EnvironmentValues {
    var settingsSearchRequest: SettingsSearchRequest? {
        get { self[SettingsSearchRequestKey.self] }
        set { self[SettingsSearchRequestKey.self] = newValue }
    }
}

private struct SettingsSearchAnchorModifier: ViewModifier {
    let anchor: String
    @Environment(\.settingsSearchRequest) private var request

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .transformPreference(SettingsSearchAnchorPreferenceKey.self) { value in
                if let request, (request.anchor ?? "settings.top") == anchor { value = request }
            }
    }
}

extension View {
    func settingsSearchAnchor(_ anchor: String) -> some View {
        modifier(SettingsSearchAnchorModifier(anchor: anchor))
    }
}

extension SettingsCategory {
    nonisolated var searchTitle: String {
        switch self {
        case .general: NSLocalizedString("通用", comment: "")
        case .appearance: NSLocalizedString("外观", comment: "")
        case .nowPlaying: NSLocalizedString("settings.section.now_playing", comment: "")
        case .fullscreen: NSLocalizedString("全屏播放", comment: "")
        case .audio: NSLocalizedString("音频", comment: "")
        case .externalPlayback: NSLocalizedString("外部播放", comment: "")
        case .library: NSLocalizedString("资料库", comment: "")
        case .data: NSLocalizedString("存储与维护", comment: "")
        case .automation: NSLocalizedString("自动化与智能", comment: "")
        case .about: NSLocalizedString("settings.section.about", comment: "")
        }
    }
}

nonisolated enum SettingsSearchIndex {
    /// The static catalogue names settings already present in the app. Skin package
    /// parameters are appended from the currently selected skins at runtime.
    static let entries: [SettingsSearchEntry] = {
        var result = [SettingsSearchEntry]()
        func add(_ category: SettingsCategory, _ tab: Int?, _ tabTitle: String?, _ anchor: String?,
                 _ items: [(String, String)]) {
            result += items.map {
                SettingsSearchEntry($0.0, category: category, tab: tab, tabTitle: tabTitle,
                                    anchor: anchor, keywords: $0.1)
            }
        }

        add(.general, nil, nil, "general.main", [
            ("托盘播放进度", "Dock 图标 进度"), ("自动更新", "检查更新 update")
        ])
        add(.general, nil, nil, "general.privacy", [
            ("帮助改进 kmgccc_player", "数据共享 匿名统计 遥测"),
            ("自动发送崩溃报告", "数据共享 隐私 错误报告")
        ])
        add(.appearance, nil, nil, "appearance.general", [
            ("动态取色", "主题 颜色 封面"), ("HDR 效果", "显示 亮度"),
            ("动态封面", "动画 视频 封面"), ("主题明暗", "浅色 深色 外观"),
            ("歌词卡片背景", "歌词 背景"), ("主页卡片材质", "主页 透明")
        ])
        add(.appearance, nil, nil, "appearance.sidebar", [("侧边栏按钮", "自定义 导航 排序")])
        add(.appearance, nil, nil, "appearance.homeOrder", [("主页板块顺序", "主页 排序")])
        add(.appearance, nil, nil, "appearance.motto", [("主页音乐座右铭", "主页 正文 翻译 注解")])
        add(.appearance, nil, nil, "appearance.toolbar", [("工具栏自定义", "按钮 工具栏")])

        for category in [SettingsCategory.nowPlaying, .fullscreen] {
            add(category, 0, "皮肤", "skin.select", [("选择外观", "皮肤 主题 自定义 导入")])
            add(category, 1, "歌词", "lyrics.appearance", [
                ("歌词渲染质量", "清晰度 性能"), ("减弱高亮", "逐字 扫光")
            ])
            add(category, 1, "歌词", "lyrics.spring", [
                ("滚动弹性", "歌词 动画 持续时间 反弹")
            ])
            add(category, 1, "歌词", "lyrics.fonts", [
                ("歌词字体", "字体 字体名称 中文 英文"),
                ("歌词字号", "字体大小 主歌词 字号"),
                ("歌词字重", "字体粗细 浅色 深色"),
                ("翻译字号与字重", "翻译 字体大小 粗细")
            ])
            add(category, 1, "歌词", "lyrics.timing", [
                ("歌词时间轴", "歌词偏移 延迟 提前量 紧邻切行阈值 歌词整体提前量")
            ])
            add(category, 1, "歌词", "lyrics.preview", [("歌词预览", "字体 效果 预览")])
        }
        add(.fullscreen, 1, "歌词", "lyrics.fonts", [
            ("按皮肤单独设置字体", "全屏 字体 皮肤")
        ])
        add(.fullscreen, 0, "皮肤", "skin.miniplayer", [
            ("Mini Player 自动隐藏", "控制栏 隐藏 秒"),
            ("Mini Player 材质", "控制栏 透明 玻璃")
        ])
        add(.fullscreen, 0, "皮肤", "skin.visual", [("封面缩放", "封面大小 视觉效果")])

        add(.audio, 0, "常规", "audio.general", [
            ("音量调节目标", "系统 播放器 音量"), ("音频延迟补偿", "频谱 可视化 同步")
        ])
        add(.audio, 0, "常规", "audio.fade", [("播放与暂停渐变", "淡入淡出 音量")])
        add(.audio, 0, "常规", "audio.loudness", [
            ("音量均衡", "响度 标准化 音量"), ("目标响度", "LUFS 音量均衡")
        ])
        add(.audio, 1, "音效与设备", "audio.device", [
            ("输出设备", "音频设备 扬声器 耳机"), ("音效预设", "音效 导入 导出"),
            ("启用音效处理", "DSP 音效")
        ])
        add(.audio, 1, "音效与设备", "audio.effects", [
            ("效果链", "音效 均衡器 EQ 混响 压缩器 声场 DSP")
        ])
        add(.externalPlayback, nil, nil, "external.main", [("从外部播放", "来源 播放器")])
        add(.externalPlayback, nil, nil, "external.apple", [("Apple Music 权限", "授权 音乐")])
        add(.externalPlayback, nil, nil, "external.other", [
            ("启用其他播放器", "外部播放 系统播放 beta"),
            ("其他播放器权限", "读取系统正在播放 授权"), ("播放来源顺序", "外部 播放器 排序")
        ])
        add(.externalPlayback, nil, nil, "external.cache", [("清理外部播放缓存", "匹配 封面 歌词")])

        add(.library, nil, nil, "library.storage", [("音乐存储方式", "资料库 引用 管理")])
        add(.library, nil, nil, "library.libraries", [("资料库", "新建 打开 切换 删除")])
        add(.library, nil, nil, "library.overview", [("资料库概览", "歌曲 专辑 格式")])
        add(.library, nil, nil, "library.sources", [("音乐来源", "文件夹 添加 扫描 同步")])
        add(.library, nil, nil, "library.deletion", [("删除歌曲", "音乐来源 偏好 删除原文件")])
        add(.library, nil, nil, "library.enrichment", [
            ("导入时延后补全歌曲信息", "歌词 封面 后台"),
            ("获取动态封面", "自动下载 视频 封面"),
            ("补全所有歌曲信息", "元数据 封面 歌词")
        ])
        add(.library, nil, nil, "library.duplicates", [("重复歌曲", "查重 合并")])
        add(.library, nil, nil, "library.missing", [("失效歌曲", "丢失 缺失 文件")])
        add(.data, 0, "后台任务", "background.general", [
            ("空闲时提前准备", "后台 电源 预加载"), ("处理节奏", "后台 轻缓 尽快")
        ])
        add(.data, 0, "后台任务", "background.tasks", [
            ("后台任务", "准备 进度 运行状态")
        ])
        add(.data, 0, "后台任务", "background.task.covers", [("封面与颜色", "后台 封面 取色")])
        add(.data, 0, "后台任务", "background.task.metadata-completion", [("歌曲资料与动态封面", "后台 补全 歌词")])
        add(.data, 0, "后台任务", "background.task.motion-alignment", [("MV 时间对齐", "后台 动态封面 视频")])
        add(.data, 0, "后台任务", "background.task.thumbnails", [("常用页面缩略图", "后台 主页 图片")])
        add(.data, 0, "后台任务", "background.task.next-song", [("下一首预加载", "后台 播放 准备")])
        add(.data, 0, "后台任务", "background.task.lyrics-index", [("歌词库更新", "后台 歌词 索引")])
        add(.data, 0, "后台任务", "background.task.maintenance", [("缓存整理", "后台 清理 缓存")])
        add(.data, 1, "存储空间", "storage.library", [("重建索引", "资料库 存储空间 扫描")])
        add(.data, 1, "存储空间", "storage.cache", [("清理缓存", "存储空间 封面 歌词 清理全部")])
        add(.data, 1, "存储空间", "storage.app", [("App 存储空间", "应用 数据 磁盘")])
        add(.data, 2, "重置", "reset.main", [("重置应用设置与状态", "恢复默认 清除设置")])
        add(.data, 2, "重置", "reset.more", [("重置播放统计数据", "更多设置 偏好 重置")])
        add(.automation, nil, nil, "automation.general", [("启用本机自动化", "MCP CLI 脚本")])
        add(.automation, nil, nil, "automation.mcp", [("MCP 接入", "自动化 MCP 配置")])
        add(.automation, nil, nil, "automation.skill", [("Agent 技能", "技能 安装 复制 指令 命令行 CLI Claude Codex WorkBuddy")])
        add(.automation, nil, nil, "automation.trusted", [("受信任的音频目录", "自动化 文件夹 授权")])
        add(.automation, nil, nil, "automation.status", [("自动化服务状态", "运行状态 诊断")])
        add(.about, nil, nil, nil, [("关于", "版本 更新 协议 隐私 许可证")])
        return result
    }()

    static func results(for query: String, entries: [SettingsSearchEntry]) -> [SettingsSearchEntry] {
        let parts = normalizedParts(query)
        let key = parts.joined()
        guard !key.isEmpty else { return [] }
        return entries.enumerated().compactMap { index, entry -> (Int, Int, SettingsSearchEntry)? in
            guard let rank = entry.rank(query: key, parts: parts) else { return nil }
            return (rank, index, entry)
        }.sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }.map { $0.2 }
    }

    fileprivate static func keys(for value: String) -> [String] {
        let plain = normalizedParts(value).joined()
        let latin = value.applyingTransform(.mandarinToLatin, reverse: false) ?? value
        let latinParts = normalizedParts(latin)
        let fullPinyin = latinParts.joined()
        let initials = latinParts.map { String($0.prefix(1)) }.joined()
        var seen = Set<String>()
        return [plain, fullPinyin, initials].filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func normalizedParts(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    fileprivate static func matchRank(_ query: String, in value: String) -> Int? {
        if query == value { return 0 }
        if value.hasPrefix(query) { return 10 }
        if value.contains(query) { return 20 }
        var index = query.startIndex
        for character in value where index < query.endIndex {
            if character == query[index] { query.formIndex(after: &index) }
        }
        if index == query.endIndex { return 30 }
        return query.count >= 3 && isOneEditApart(query, value) ? 40 : nil
    }

    private static func isOneEditApart(_ query: String, _ value: String) -> Bool {
        let left = Array(query)
        let right = Array(value)
        guard abs(left.count - right.count) <= 1 else { return false }
        var i = 0
        var j = 0
        var edited = false
        while i < left.count && j < right.count {
            if left[i] == right[j] {
                i += 1
                j += 1
                continue
            }
            guard !edited else { return false }
            edited = true
            if left.count == right.count {
                if i + 1 < left.count, j + 1 < right.count,
                   left[i] == right[j + 1], left[i + 1] == right[j] {
                    i += 2
                    j += 2
                } else {
                    i += 1
                    j += 1
                }
            } else if left.count > right.count {
                i += 1
            } else {
                j += 1
            }
        }
        return !edited || (i == left.count && j == right.count)
    }
}
