//
//  WhatsNewConfiguration.swift
//  myPlayer2
//
//  kmgccc_player - WhatsNewKit configuration for feature announcements
//

import SwiftUI
import WhatsNewKit

// MARK: - WhatsNew Configuration

enum WhatsNewConfiguration {

    /// First-install onboarding overview for new users.
    static let welcome = WhatsNew(
        title: "欢迎使用 kmgccc_player",
        features: [
            WhatsNew.Feature(
                image: .init(systemName: "square.stack.3d.up.fill", foregroundColor: .indigo),
                title: "本地曲库管理",
                subtitle: "自动联网搜索封面、歌词与元数据，省心且稳定。更有关键词搜歌、卡片展示等趣味功能。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "sparkles.rectangle.stack.fill", foregroundColor: .pink),
                title: "别出心裁的播放界面",
                subtitle: SkinRegistry.customizationEnabled
                    ? "动态取色，艺术背景，自定义皮肤，旨在提供不一样的聆听体验。"
                    : "动态取色与艺术背景，提供不一样的聆听体验。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "slider.vertical.3", foregroundColor: .orange),
                title: "专业音频处理",
                subtitle: "内置 DSP 音效处理链，支持参数均衡、等响度补偿和自定义效果等，听到你想要的声音。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "waveform.path.ecg.rectangle.fill", foregroundColor: .green),
                title: "实时音频可视化",
                subtitle: "从 LED 到 Apple 风格频谱，在简约几何中感受音乐律动。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "point.3.connected.trianglepath.dotted", foregroundColor: .purple),
                title: "MCP 与自动化协议支持",
                subtitle: "内置 MCP 协议，可连接 AI Agent，自动完成复杂曲库整理、元数据修改与播放管理。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )

    /// The current What's New content. Display version is separate from the build gate.
    static let current = WhatsNew(
        version: WhatsNewConfig.whatsNewVersion,
        title: "什么是新的",
        features: [
            WhatsNew.Feature(
                image: .init(systemName: "books.vertical", foregroundColor: .orange),
                title: "资料库修复",
                subtitle: "修复打开或移除资料库时可能退出，以及已移入废纸篓的资料库仍显示的问题。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "checkmark.circle", foregroundColor: .green),
                title: "更新公告",
                subtitle: "点击“继续”后可正常关闭更新公告。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "livephoto", foregroundColor: .pink),
                title: "Apple Music 动态封面",
                subtitle: "为歌曲或专辑查找动态封面，也可以导入自己的视频。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "slider.horizontal.3", foregroundColor: .orange),
                title: "侧边栏快捷按钮",
                subtitle: "自己选择和排列常用按钮，最多放四个。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "photo.badge.arrow.down", foregroundColor: .blue),
                title: "更新旧封面",
                subtitle: "为部分旧歌曲重新查找更清晰的封面。任务可暂停或结束；旧曲库中来源不明的手动封面可能会被替换。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "photo", foregroundColor: .green),
                title: "改善封面画质",
                subtitle: "保存封面时尽量保留原图，切换歌曲时封面衔接也更快。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "pencil.line", foregroundColor: .purple),
                title: "保留手动修改",
                subtitle: "自动补充歌曲资料时，会保留你手动修改的内容。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
