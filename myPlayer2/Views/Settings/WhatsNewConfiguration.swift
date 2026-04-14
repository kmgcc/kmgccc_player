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
                image: .init(systemName: "text.magnifyingglass", foregroundColor: .indigo),
                title: "AMLL DB 歌词查找",
                subtitle: "现已支持通过 AMLL DB 搜索来自开源社区的高质量歌词。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "dock.rectangle", foregroundColor: .blue),
                title: "全屏控制栏焕新",
                subtitle: "底部控制栏自动显隐，并支持不同玻璃材质，带来更沉浸也更灵活的界面体验。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "square.and.arrow.down.on.square", foregroundColor: .mint),
                title: "导入后后台补全歌曲信息",
                subtitle: "导入歌曲时，现可选择在后台补全封面、歌词等信息。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "shuffle.circle", foregroundColor: .green),
                title: "随机播放偏好记录",
                subtitle: "随机播放现可结合您的聆听习惯进行调整，带来更符合偏好的播放体验。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "list.bullet.rectangle", foregroundColor: .orange),
                title: "全屏播放队列",
                subtitle: "全屏模式现已支持显示播放队列。再次点按播放顺序按钮，即可快速打开当前队列。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
