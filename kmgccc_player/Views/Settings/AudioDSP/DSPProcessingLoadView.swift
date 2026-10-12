import SwiftUI

/// Narrow observation boundaries keep low-frequency measurements out of the
/// rack's editors, response plots and pointer-driven reordering state.
struct DSPProcessingLoadBadge: View {
    let presentation: DSPProcessingLoadPresentation
    let isEnabled: Bool
    let isLive: Bool
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var load: DSPProcessingLoad? {
        guard isLive, let snapshot = presentation.snapshot else { return nil }
        return snapshot.chain
    }

    var body: some View {
        let load = self.load
        HStack(spacing: 4) {
            Text("负载")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let load {
                Circle()
                    .fill(themeStore.semanticPalette.dspProcessingLoadColor(load, colorScheme: colorScheme, isChain: true))
                    .frame(width: 6, height: 6)
            }
            Text(load.map { $0.averageRatio.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 42, alignment: .trailing)
        .fixedSize()
        .help(helpText(for: load))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("整链负载")
        .accessibilityValue(load.map { $0.averageRatio.formatted(.percent.precision(.fractionLength(1))) } ?? "暂无测量")
    }

    private func helpText(for load: DSPProcessingLoad?) -> String {
        guard isLive else { return "测量随当前播放设备更新。" }
        guard let load else { return "播放时测量处理负载。" }
        guard isEnabled else { return "上次测量 \(load.averageRatio.formatted(.percent.precision(.fractionLength(1))))" }
        let milliseconds = (load.averageRatio * 1_000).formatted(.number.precision(.fractionLength(1)))
        let peak = load.sampledPeakRatio.formatted(.percent.precision(.fractionLength(1)))
        return "每秒音频处理耗时 \(milliseconds) ms\n近期抽样峰值 \(peak)\n负载为处理耗时占音频时长的比例，包含前瞻计算。"
    }
}

struct DSPProcessingLoadSurface: View {
    let presentation: DSPProcessingLoadPresentation
    let nodeID: UUID
    let isEnabled: Bool
    let isLive: Bool
    let baseColor: Color
    let isExpanded: Bool
    let headerHeight: CGFloat
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        guard isEnabled, isLive, let load = presentation.snapshot?.nodes[nodeID] else { return baseColor }
        let tint = themeStore.semanticPalette.dspProcessingLoadColor(load, colorScheme: colorScheme)
        let strength = isExpanded
            ? (colorScheme == .dark ? 0.05 : 0.065)
            : (colorScheme == .dark ? 0.12 : 0.14)
        return baseColor.mix(with: tint, by: strength, in: .device)
    }

    var body: some View {
        let headerColor = color
        let tintHeight = headerHeight + 10
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isExpanded ? baseColor : headerColor)
            .overlay(alignment: .top) {
                if isExpanded {
                    // Soften the bottom of the header, leaving only a faint
                    // ten-point tail in the editor. Fixed stops need no blur,
                    // offscreen mask or geometry read as the editor grows.
                    LinearGradient(stops: [
                        .init(color: headerColor, location: 0),
                        .init(color: headerColor, location: (headerHeight - 4) / tintHeight),
                        .init(color: headerColor.mix(with: baseColor, by: 0.5, in: .device), location: (headerHeight + 3) / tintHeight),
                        .init(color: headerColor.mix(with: baseColor, by: 0.9, in: .device), location: (headerHeight + 7) / tintHeight),
                        .init(color: baseColor, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: tintHeight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
