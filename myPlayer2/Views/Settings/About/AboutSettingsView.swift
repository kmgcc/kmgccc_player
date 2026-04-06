//
//  AboutSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - About Settings View
//

import SwiftUI

/// About page with app info, licenses, and social links.
struct AboutSettingsView: View {
    @State private var aboutEasterEggTracker = AboutEasterEggTapTracker()
    @State private var showEasterEggImage: Bool = false

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 40)

            Image(showEasterEggImage ? "jntm" : "EmptyLyric")
                .resizable()
                .scaledToFit()
                .frame(width: 230, height: 230)
                .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)

            VStack(spacing: 8) {
                Text(Constants.appName)
                    .font(.title.bold())
                Text(
                    String(
                        format: NSLocalizedString("settings.about.version", comment: ""),
                        Constants.appVersion)
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Text(NSLocalizedString("settings.about.quote", comment: ""))
                .font(.body)
                .fontWeight(.ultraLight)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
                .padding(.top, 12)

            Spacer()

            Divider()
                .padding(.vertical, 32)

            HStack(spacing: 10) {
                socialIconLink(
                    title: "哔",
                    hexColor: "fb7299",
                    destination: "https://space.bilibili.com/1605472940"
                )
                socialIconLink(
                    title: "码",
                    hexColor: "020408",
                    destination: "https://github.com/kmgcc"
                )
                socialIconLink(
                    title: "书",
                    hexColor: "f72241",
                    destination: "https://xhslink.com/m/7o53GE3YNQy"
                )

                Link(
                    "查看更新",
                    destination: URL(string: "https://github.com/kmgcc/kmgccc_player/releases")!
                )
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
            .padding(.bottom, 34)

            complianceSection

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .overlay {
            easterEggOverlay
        }
    }

    private var complianceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(NSLocalizedString("settings.about.compliance", comment: ""))
                .font(.headline)

            Text("settings.about.compliance_desc")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                complianceItem(
                    name: "applemusic-like-lyrics",
                    url: "https://github.com/amll-dev/applemusic-like-lyrics",
                    license: "AGPL-3.0"
                )
                complianceItem(
                    name: "apple-audio-visualization",
                    url: "https://github.com/taterboom/apple-audio-visualization",
                    license: nil
                )
                complianceItem(
                    name: "LDDC",
                    url: "https://github.com/chenmozhijin/LDDC",
                    license: "GPL-3.0"
                )
                complianceItem(
                    name: "sacad",
                    url: "https://github.com/desbma/sacad",
                    license: "MPL-2.0"
                )
                complianceItem(
                    name: "ncmdump",
                    url: "https://github.com/taurusxin/ncmdump",
                    license: "MIT"
                )
                complianceItem(
                    name: "WhatsNewKit",
                    url: "https://github.com/SvenTiigi/WhatsNewKit",
                    license: "MIT"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("settings.about.source_code")
                    .font(.subheadline.bold())
                Text("settings.about.source_code_desc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    "https://github.com/kmgccc/kmgccc_player",
                    destination: URL(string: "https://github.com/kmgcc/kmgccc_player")!
                )
                .font(.caption)
            }
            .padding(.top, 10)

            Text("settings.about.license")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("版权与素材声明")
                    .font(.headline)
                Text(
                    "本项目中所使用的所有美术素材，包括但不限于界面插画、UI 装饰、皮肤、贴图、角色设计、视觉元素，均为作者原创作品。"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(
                    "上述美术素材 不属于开源代码的一部分，亦 不适用 AGPL-3.0 许可证。\n未经明确许可，不得对这些素材进行复制、修改、再分发或用于 AI 训练等其他项目。"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Text("settings.about.copyright")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var easterEggOverlay: some View {
        GeometryReader { proxy in
            let minimumSideWidth: CGFloat = 72
            let centerWidth = min(
                560,
                max(280, proxy.size.width - minimumSideWidth * 2)
            )
            let sideWidth = max(0, (proxy.size.width - centerWidth) / 2)

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: sideWidth, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { handleAboutTap(on: .left) }

                Color.clear
                    .frame(width: centerWidth, height: proxy.size.height)
                    .allowsHitTesting(false)

                Color.clear
                    .frame(width: sideWidth, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { handleAboutTap(on: .right) }
            }
        }
        .allowsHitTesting(true)
    }

    private func handleAboutTap(on side: AboutTapSide) {
        if aboutEasterEggTracker.registerTap(on: side) {
            showEasterEggImage = true
            NotificationCenter.default.post(name: .aboutEasterEggTriggered, object: nil)
        }
    }

    private func complianceItem(name: String, url: String, license: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.bold())
                Link(url, destination: URL(string: url)!)
                    .font(.caption)
            }
            Spacer()
            if let license = license {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                    Text(license)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(licenseColor(for: license).opacity(0.15))
                )
                .foregroundStyle(licenseColor(for: license))
            }
        }
    }

    private func licenseColor(for license: String) -> Color {
        switch license {
        case "MIT": return .green
        case "GPL-3.0", "AGPL-3.0": return .blue
        case "MPL-2.0": return .purple
        case "Apache-2.0": return .teal
        case "BSD": return .cyan
        default: return .secondary
        }
    }

    private func socialIconLink(title: String, hexColor: String, destination: String) -> some View {
        Link(destination: URL(string: destination)!) {
            Circle()
                .fill(Color(hex: hexColor) ?? .secondary)
                .frame(width: 30, height: 30)
                .overlay {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About Easter Egg Support Types

private enum AboutTapSide {
    case left
    case right
}

private struct AboutEasterEggTapTracker {
    private static let requiredTapCount = 4
    private static let minInterval: TimeInterval = 0.14
    private static let maxInterval: TimeInterval = 1.05

    private var lastSide: AboutTapSide?
    private var lastTapTime: TimeInterval?
    private var tapCount: Int = 0

    mutating func registerTap(
        on side: AboutTapSide, now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Bool {
        guard let previousSide = lastSide, let previousTime = lastTapTime else {
            lastSide = side
            lastTapTime = now
            tapCount = 1
            return false
        }

        let interval = now - previousTime
        let isAlternating = previousSide != side
        let isTimingValid = interval >= Self.minInterval && interval <= Self.maxInterval

        if isAlternating && isTimingValid {
            tapCount += 1
            lastSide = side
            lastTapTime = now

            if tapCount >= Self.requiredTapCount {
                reset()
                return true
            }
            return false
        }

        lastSide = side
        lastTapTime = now
        tapCount = 1
        return false
    }

    private mutating func reset() {
        lastSide = nil
        lastTapTime = nil
        tapCount = 0
    }
}