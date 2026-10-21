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
                subtitle: "动态取色，艺术背景，自定义皮肤，旨在提供不一样的聆听体验。"
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
                image: .init(systemName: "slider.vertical.3", foregroundColor: .blue),
                title: "专业音频处理与音效",
                subtitle: "加入歌曲音量均衡、平滑淡入淡出与等响度补偿，以及可高度自定义的 DSP 链路，听到你想要的声音。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "hand.draw", foregroundColor: .orange),
                title: "支持曲目拖动管理",
                subtitle: "支持键盘快捷多选与自由拖拽，可直接拖动曲目归类至播放列表，或快速加入播放队列。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "gauge.with.needle", foregroundColor: .purple),
                title: "智能后台调度",
                subtitle: "依据系统负载与聆听状况，在设备空闲时段静默执行音频分析与缓存预备，保持播放流畅，不被打扰。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "internaldrive", foregroundColor: .green),
                title: "存储空间统计与维护",
                subtitle: "设置中新增存储分析面板，清晰查看曲库与各级缓存占用，支持一键安全清理以释放磁盘空间。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "memorychip", foregroundColor: .pink),
                title: "内存占用优化",
                subtitle: "结合 SwiftUI 特性对内存占用进行全面检查与优化，在提升显示效果的同时降低了内存占用。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
