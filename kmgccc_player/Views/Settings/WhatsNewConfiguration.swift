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

    /// The current What's New content. Display version is separate from the build gate.
    static let current = WhatsNew(
        version: WhatsNewConfig.whatsNewVersion,
        title: "什么是新的",
        features: [
            WhatsNew.Feature(
                image: .init(systemName: "speedometer", foregroundColor: .indigo),
                title: "性能优化",
                subtitle: "歌曲切换、主页浏览与播放列表滚动的流畅度均有明显提升。我们也持续调整缓存与资源释放，尝试缓解内存占用，并处理歌词组件异常消耗资源的问题。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "point.3.connected.trianglepath.dotted", foregroundColor: .green),
                title: "Agent MCP 接入",
                subtitle: "在设置中开启本机自动化并复制 MCP 配置后，支持的智能助手可查询曲库、歌词与播放列表；需要额外授权的操作仍由播放器确认。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
