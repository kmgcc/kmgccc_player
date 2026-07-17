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
        title: "这一程，音乐自然相连",
        features: [
            WhatsNew.Feature(
                image: .init(systemName: "waveform.path", foregroundColor: .indigo),
                title: "无缝播放",
                subtitle: "专辑里的歌曲紧紧相连，曲目之间不再留下多余的停顿，让一张唱片完整地流淌。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "waveform", foregroundColor: .blue),
                title: "窗口 MiniPlayer",
                subtitle: "实时音频可视化让节奏继续留在窗口里，播放中的每一拍都有可见的回应。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "arrow.up.arrow.down", foregroundColor: .green),
                title: "拖动整理歌曲",
                subtitle: "进入多选模式后，拖动一首或多首歌曲即可整理专辑与播放列表的顺序，音乐按心意排列。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "rectangle.inset.filled", foregroundColor: .purple),
                title: "全屏过渡更柔和",
                subtitle: "全景皮肤加入交叠模糊过渡，封面与歌词切换时，画面在光影之间自然衔接。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "text.magnifyingglass", foregroundColor: .pink),
                title: "在歌词里搜索",
                subtitle: "想起一句歌词，也能找到对应的歌曲与时间，点按匹配结果即可从那一句开始播放。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
