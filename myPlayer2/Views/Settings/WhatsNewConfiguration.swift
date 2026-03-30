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

    /// The current app version's What's New content
    static let current = WhatsNew(
        version: "1.2.1",
        title: "kmgccc player 新功能！",
        features: [
            WhatsNew.Feature(
                image: .init(systemName: "rectangle.inset.filled.and.person.filled", foregroundColor: .indigo),
                title: "全屏播放，焕然一新",
                subtitle: "现已支持全屏播放，并带来全新的全屏封面皮肤，沉浸感与视觉表现进一步提升。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "music.note.list", foregroundColor: .blue),
                title: "资料库更完善",
                subtitle: "现已支持导入 NCM 格式，自动匹配歌词，并支持联网查找歌曲封面，导入与整理体验更加完整。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "paintbrush", foregroundColor: .orange),
                title: "外观与动效同步升级",
                subtitle: "进一步优化界面细节，新增皮肤频谱动画，让播放器在观感与反馈上更加细腻生动。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "speedometer", foregroundColor: .green),
                title: "性能显著优化",
                subtitle: "针对资源占用进行了重点优化，大幅降低内存与性能压力，整体运行更加轻快稳定。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
