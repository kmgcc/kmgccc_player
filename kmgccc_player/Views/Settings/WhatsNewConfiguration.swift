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
                image: .init(systemName: "headphones", foregroundColor: .blue),
                title: "空间音频",
                subtitle: "支持 Apple 空间音频，配合兼容的耳机，可开启环绕声场和头部跟踪。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "folder.fill", foregroundColor: .green),
                title: "多资料库与就地入库",
                subtitle: "可创建并切换多个曲库，也可直接添加本地文件夹，无需复制或移动文件。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "speaker.wave.2.fill", foregroundColor: .purple),
                title: "滚轮调节音量",
                subtitle: "全屏播放时，在封面区域滑动滚轮或双指轻扫触控板，即可快捷调节音量。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "doc.text", foregroundColor: .orange),
                title: "更舒展的详情阅读",
                subtitle: "点击专辑或艺人的介绍文字，可在大窗口中阅读完整内容；全屏播放时右键也能查看。"
            ),
            WhatsNew.Feature(
                image: .init(systemName: "sun.max.fill", foregroundColor: .yellow),
                title: "HDR 点缀",
                subtitle: "在支持的 XDR 显示屏上，LED 仪表可使用高动态范围显示，亮度更高、对比更鲜明。"
            )
        ],
        primaryAction: .init(
            title: "继续",
            backgroundColor: .accentColor
        )
    )
}
