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
                image: .init(systemName: "music.note.list", foregroundColor: .indigo),
                title: "原生 Swift 歌词引擎",
                subtitle: "歌词全面迁移至原生 Swift 实现，带来更丝滑流畅的逐字动效与更精准的节奏同步，并大幅降低系统资源占用。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "arrow.down.circle.fill", foregroundColor: .green),
                title: "无缝自动更新",
                subtitle: "新版本支持在后台静默下载，更新完成后只需重启应用即可直接完成升级安装，无需再手动打开 DMG 镜像。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
