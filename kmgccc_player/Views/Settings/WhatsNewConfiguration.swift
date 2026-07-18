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
                image: .init(systemName: "waveform.path", foregroundColor: .indigo),
                title: "无缝播放",
                subtitle: "为那些别出心裁的无缝专辑准备。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "waveform", foregroundColor: .blue),
                title: "刷新的音频可视化者",
                subtitle: "享受动画的音频、视觉，即使在全屏之外，或者把它们放进进度条，随着你的音乐移动。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "arrow.up.arrow.down", foregroundColor: .green),
                title: "拖动重新排序",
                subtitle: "在多选模式，抓住一个或更多歌曲来重新排列专辑和播放列表，就按你喜欢的方式。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "rectangle.inset.filled", foregroundColor: .purple),
                title: "更柔软的全荧幕转化",
                subtitle: "全景皮肤现在以覆盖模糊过渡为特性，在插图和歌词之间制造一个无线缝的流动。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "text.magnifyingglass", foregroundColor: .pink),
                title: "在歌词中搜索",
                subtitle: "寻找歌曲，通过寻找单词在它们的歌词中，然后直接跳到符合的行"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
