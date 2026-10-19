import SwiftUI
import AppKit

public struct MainLabView: View {
    @StateObject private var engine = AudioPlayerEngine()
    @State private var isDraggingSlider = false
    @State private var dragSliderValue: Double = 0.0

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部导航与曲目信息
            headerView
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // 播放与电平控制
                    playbackCard
                    // 算法切换选择
                    modeSelectionCard
                    // 实时参数调节面板
                    parametersCard
                    // 调试对比与听感指引
                    guidanceCard
                }
                .padding(24)
            }
        }
        .frame(minWidth: 780, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.currentFileName)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(engine.currentFormatDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if engine.isPlaying {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("正在实时 DSP 渲染")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                }
            }

            Spacer()

            Button(action: openAudioFile) {
                Label("导入音频歌曲", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    // MARK: - 播放与电平表
    private var playbackCard: some View {
        VStack(spacing: 16) {
            // 进度条
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { isDraggingSlider ? dragSliderValue : (engine.duration > 0 ? engine.currentTime / engine.duration : 0) },
                        set: { dragSliderValue = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        isDraggingSlider = editing
                        if !editing {
                            engine.seek(to: dragSliderValue)
                        }
                    }
                )
                HStack {
                    Text(formatTime(isDraggingSlider ? dragSliderValue * engine.duration : engine.currentTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(engine.duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // 控制按钮与音量、电平
            HStack(spacing: 24) {
                Button(action: { engine.togglePlayPause() }) {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                // 音量推子
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.1.fill")
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(engine.volume) },
                            set: { engine.setVolume(Float($0)) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 110)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 实时双声道立体声电平表
                VStack(alignment: .trailing, spacing: 4) {
                    meterBar(label: "L", value: engine.leftMeter)
                    meterBar(label: "R", value: engine.rightMeter)
                }
                .frame(width: 170)

                // 削波警告指示灯
                VStack(spacing: 2) {
                    Circle()
                        .fill(engine.isClipping ? Color.red : Color.gray.opacity(0.3))
                        .frame(width: 14, height: 14)
                        .shadow(color: engine.isClipping ? .red : .clear, radius: 4)
                    Text("CLIP")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(engine.isClipping ? .red : .secondary)
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func meterBar(label: String, value: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(meterColor(for: value))
                        .frame(width: geo.size.width * CGFloat(min(1.0, value)))
                }
            }
            .frame(height: 7)
        }
    }

    private func meterColor(for value: Float) -> Color {
        if value > 0.95 { return .red }
        if value > 0.75 { return .yellow }
        return .green
    }

    // MARK: - 模式选择
    private var modeSelectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("虚拟低音算法模式 (实时切换对比)")
                .font(.system(size: 14, weight: .semibold))

            Picker("", selection: $engine.mode) {
                ForEach(VirtualBassMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // 当前模式说明标签
            HStack(spacing: 8) {
                Image(systemName: modeIcon(engine.mode))
                    .foregroundColor(modeColor(engine.mode))
                Text(modeDescription(engine.mode))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - 参数调节推子
    private var parametersCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("算法参数实时调节")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("重置默认") {
                    engine.params = VirtualBassParams()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            VStack(spacing: 14) {
                paramRow(title: "虚拟强度 Intensity (超宽动态)", value: String(format: "%.2f x", engine.params.intensity), range: 0.0...3.5, binding: $engine.params.intensity)

                // 混合版专属核心参数：瞬态/动态
                VStack(alignment: .leading, spacing: 4) {
                    paramRow(title: "动态 / 瞬态 Transient (混合版专属)", value: String(format: "%.2f x", engine.params.transient), range: 0.0...2.0, binding: $engine.params.transient)
                    Text("控制底鼓与冲击瞬态 (Punch)：调大时鼓点结实震撼、拳拳到肉；调小时声音柔和温润。")
                        .font(.system(size: 11))
                        .foregroundColor(engine.mode == .fixedHybrid ? .accentColor : .secondary)
                }
                .padding(8)
                .background(engine.mode == .fixedHybrid ? Color.accentColor.opacity(0.08) : Color.clear)
                .cornerRadius(8)

                paramRow(title: "音色性格 Character (紧凑 Tight ⟷ 浑厚 Round)", value: engine.params.character < 0.4 ? "紧凑清晰 (Tight)" : (engine.params.character > 0.7 ? "圆润饱满 (Round)" : "平衡 (Balanced)"), range: 0.0...1.0, binding: $engine.params.character)

                paramRow(title: "截止频率 Cutoff", value: String(format: "%.0f Hz", engine.params.cutoffHz), range: 60...180, binding: $engine.params.cutoffHz)
                paramRow(title: "真实低音增益 Bass Shelf", value: String(format: "+%.1f dB", engine.params.bassGainDB), range: 0.0...12.0, binding: $engine.params.bassGainDB)
                paramRow(title: "输出修剪 Trim", value: String(format: "%+.1f dB", engine.params.outputTrimDB), range: -12.0...6.0, binding: $engine.params.outputTrimDB)

                Divider()

                HStack(spacing: 20) {
                    Toggle(isOn: $engine.params.wetSolo) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("纯湿声监听 (Wet Solo)")
                                .font(.system(size: 13, weight: .medium))
                            Text("静音原声干声，只听生成的虚拟低音层，检查谐波纯度")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Spacer()

                    Toggle(isOn: $engine.params.tightenDryBass) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("切除干声超低频 (Tighten)")
                                .font(.system(size: 13, weight: .medium))
                            Text("模拟小喇叭：切掉超低物理抖动，仅靠虚拟谐波发声")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func paramRow(title: String, value: String, range: ClosedRange<Double>, binding: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: binding, in: range)
        }
    }

    // MARK: - 听感对比指引
    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.orange)
                Text("如何快速验证杂音与修复效果？")
                    .font(.system(size: 13, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("1. **复现破音**：导入一首带节奏鼓点或低音重击的歌曲，选择【原版经典】，将强度调至 1.2 以上。戴上耳机仔细听低频敲击处，会明显听到“噗噗噗”的断崖式爆音，右上方 CLIP 灯频繁亮红。")
                Text("2. **验证修复**：切换至【修复版经典】，由于串联了 4 阶 Butterworth Post-HPF 彻底切断了 < fc 的次声波差频，并由平滑动态限幅替代了硬削波，低音立刻变得饱满、凝聚、极富弹性和下潜感，且完全没有任何杂音与破音！")
                Text("3. **盲听直通对比**：随时切到【直通 (Bypass)】，可明显对比缺失基频（Missing Fundamental）带来的震撼低音延展。")
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .lineSpacing(3)
        }
        .padding(16)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
    }

    private func openAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]

        if panel.runModal() == .OK, let url = panel.url {
            engine.loadFile(url: url)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func modeIcon(_ mode: VirtualBassMode) -> String {
        switch mode {
        case .bypass: return "waveform"
        case .originalClassic, .originalHybrid: return "exclamationmark.triangle.fill"
        case .fixedClassic, .fixedHybrid: return "checkmark.seal.fill"
        }
    }

    private func modeColor(_ mode: VirtualBassMode) -> Color {
        switch mode {
        case .bypass: return .secondary
        case .originalClassic, .originalHybrid: return .red
        case .fixedClassic, .fixedHybrid: return .green
        }
    }

    private func modeDescription(_ mode: VirtualBassMode) -> String {
        switch mode {
        case .bypass:
            return "关闭虚拟低音效果，直接播放原始输入音频。"
        case .originalClassic:
            return "原版经典：包含 max(envelope, amplitude) 拍频跳变与逐点瞬时硬截断，易产生噗噗马达破音声。"
        case .fixedClassic:
            return "修复版经典 (推荐)：4阶 Post-HPF 彻底切断次声波差频，2/3次平滑谐波，无削波碎裂破音。"
        case .originalHybrid:
            return "原版混合：复用原版 ClassicBass，带有时频分解与降采样振铃失真。"
        case .fixedHybrid:
            return "修复版混合 (推荐)：瞬态采用有界软饱和保留鼓点冲击力，稳态音调解析生成倍频，全频干净通透。"
        }
    }
}
