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
        version: WhatsNewConfig.whatsNewVersion,
        title: "kmgccc player 新功能！",
        features: [
            WhatsNew.Feature(
                image: .init(systemName: "music.note.house.fill", foregroundColor: .indigo),
                title: "全新 Home 页面",
                subtitle: "浏览专辑、艺人、播放列表与每周排行，音乐世界尽收眼底。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "opticaldisc.fill", foregroundColor: .blue),
                title: "资料库全面升级",
                subtitle: "支持自定义资料库位置，扫描、补全与批量管理更加得心应手。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "arrow.up.left.and.arrow.down.right", foregroundColor: .orange),
                title: "窗口全屏播放",
                subtitle: "点按正在播放的封面即可进入全屏模式，随时调整显示效果与皮肤。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "waveform", foregroundColor: .green),
                title: "LED 模拟焕新",
                subtitle: "采用 OKLCH 颜色体系与呼吸灯效果，重现经典播放器的温暖质感。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "clock.arrow.circlepath", foregroundColor: .purple),
                title: "播放记忆",
                subtitle: "重新打开 App，自动恢复上次播放状态，无缝继续聆听。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
