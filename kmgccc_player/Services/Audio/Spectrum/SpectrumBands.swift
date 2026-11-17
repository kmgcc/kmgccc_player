// 频段划分 + 前级分箱：段数可扩展的真正实现。
//
// 6 段时逐字复刻 Apple 的 MRUWaveformView 参数（1024 点 Hann / hop 2048 /
// 边界 20-81-170-527-1500-4500-10000）。段数 > 6 时不是把 6 个值插值或平滑，
// 而是把每个原始频带按对数带宽继续切开，每一段各自对 FFT 幅度谱独立求和；
// 同时把分析窗自动放长，保证最窄的那一段里至少有 2 个频点。
import Foundation
import Accelerate
import AVFoundation

nonisolated struct BandLayout: Sendable {
    let edges: [Double]
    /// FFT bin width this layout was built for. 0 = unknown.
    let binWidth: Double
    /// 每段来自哪一条 Apple 原始频带（0…5）。6 段时就是恒等映射。
    let parent: [Int]

    init(edges: [Double], parent: [Int]? = nil, binWidth: Double = 0) {
        self.edges = edges
        self.parent = parent ?? Array(0..<max(0, edges.count - 1))
        self.binWidth = binWidth
    }

    /// 把 6 个母带标定值按对数频率摊到任意段中心。锚点就是六条带的几何中心，
    /// 段间用 smoothstep（线性插值会在锚点上折角，柱子到那里会突然换斜率）。
    /// 段数 = 6 时段中心正好落在锚点上，取值与 v[i] 逐位相同，所以 6 段链路不受影响。
    static func smoothCal(_ v: [Double], at f: Double) -> Double {
        guard v.count >= 6 else { return v.first ?? 0 }
        let c = anchors
        let x = log2(max(f, 1e-9))
        if x <= c[0] { return v[0] }
        if x >= c[5] { return v[5] }
        for i in 0..<5 where x < c[i + 1] {
            let t = (x - c[i]) / (c[i + 1] - c[i])
            let s = t * t * (3 - 2 * t)
            return v[i] + (v[i + 1] - v[i]) * s
        }
        return v[5]
    }

    /// 六个锚点的对数频率（Apple 六条带的几何中心）。
    static let anchors: [Double] =
        (0..<6).map { log2((appleEdges[$0] * appleEdges[$0 + 1]).squareRoot()) }


    /// 子段的「能量密度」换算系数：FFT 求和是按段内频点数累加的，
    /// 把一条带切成 4 段，每段的绝对和会小 4 倍。乘上 parentWidth/width 就把
    /// 子段还原成与母带同一量级的谱密度，鱼形走势才不会被切碎。
    /// 把子段能量换算回母带带宽：FFT 求和是按频点数累加的，切成 q 段每段只剩 1/q，
    /// 乘 pw/width 之后「平谱时段段都等于母带值」，六段标定才能原样沿用。
    ///
    /// 这里**不设上限**。上限只在全局量纲稳不住时才需要（那时窄段被 5 倍放大直接顶到 1.0）；
    /// 现在量纲由粗窗/细窗的原始和之比逐拍归一，36 段时每个母带切 6 段，任何上限都会把
    /// 高频整条压低——实测上限 2 时顶端只剩 0.10，取消后是 0.35。
    var densityScale: [Double] {
        (0..<count).map { i in
            let p = min(max(parent[i], 0), 5)
            guard binWidth > 0 else {
                let pw = BandLayout.appleEdges[p + 1] - BandLayout.appleEdges[p]
                return pw / widths[i]
            }
            // Apple sums |X| over whole bins, so the band's value is
            // (bins in the band) × (mean bin magnitude). Converting a sub-band
            // back to the parent's scale therefore multiplies by the *bin count*
            // ratio — using the Hz width ratio instead over-amplifies any band
            // that only holds one or two bins (measured: 2× hot).
            let selfBins = binCount(from: edges[i], to: edges[i + 1])
            let parentBins = binCount(
                from: p == 0 ? edges[0] : BandLayout.appleEdges[p],
                to: BandLayout.appleEdges[p + 1]
            )
            return parentBins / selfBins
        }
    }

    /// Number of FFT bins whose centres fall inside [lo, hi).
    private func binCount(from lo: Double, to hi: Double) -> Double {
        let first = (lo / binWidth).rounded(.up)
        let last = (hi / binWidth).rounded(.up)
        return max(1, last - first)
    }

    var count: Int { max(0, edges.count - 1) }
    var centres: [Double] { (0..<count).map { (edges[$0] * edges[$0 + 1]).squareRoot() } }
    var widths: [Double] { (0..<count).map { edges[$0 + 1] - edges[$0] } }
    var octaves: [Double] { (0..<count).map { log2(edges[$0 + 1] / edges[$0]) } }

    /// Apple 实测的 7 个边界（8 条灵动岛录屏那一版口径）。
    static let appleEdges: [Double] = [20, 81, 170, 527, 1500, 4500, 10000]

    /// 生成 n 段边界。
    ///
    /// n = 6 时原样返回 Apple 的七条边界。n > 6 时：
    ///
    /// 1. **按八度（对数带宽）比例分配柱子**，不是按 6 等分。6 等分时高频那条母带
    ///    总是最后一个拿到多余的名额，段数一多就长出一大排高频柱、低频几乎没有，
    ///    同一段音乐换个窗口宽度整体配比就变了。按八度分，每根柱子覆盖的八度数
    ///    恒定，段数变化时各频段占的柱子数比例不变。
    /// 2. **每段至少一个频点**，装不下的名额按「当前每根柱子覆盖的八度数」从大到小
    ///    补给还有频点余量的母带。
    /// 3. 段边界落在频点边界上，段宽因此不是严格等比，肉眼看不出来。
    /// 4. 多段时显示下限抬到 `lowEdge`：20–40 Hz 在八条参考曲里几乎为空
    ///    （手机录放都滚掉了），切出两段以上最左边永远是根矮桩。
    static func make(count n: Int, binWidth: Double, lowEdge: Double = 20) -> BandLayout {
        let base = appleEdges
        guard n > 6 else { return BandLayout(edges: base, binWidth: binWidth) }
        let lo0 = min(max(lowEdge, 20), base[1] * 0.9)

        // 每条母带的显示下限与频点范围
        let lows = (0..<6).map { $0 == 0 ? lo0 : base[$0] }
        func firstBin(_ p: Int) -> Int { Int(ceil(lows[p] / binWidth - 1e-9)) }
        func lastBin(_ p: Int) -> Int { Int(ceil(base[p + 1] / binWidth - 1e-9)) }
        let avail = (0..<6).map { max(1, lastBin($0) - firstBin($0)) }
        let oct = (0..<6).map { log2(base[$0 + 1] / lows[$0]) }
        let totalOct = oct.reduce(0, +)

        // 理想分配 = n × 该母带的八度占比；先取整（并夹在该母带能分出的段数内），
        // 再按余数补齐，保证总数正好是 n。
        let ideal = oct.map { Double(n) * $0 / totalOct }
        var alloc = (0..<6).map { min(max(1, Int(ideal[$0])), avail[$0]) }
        var carry = (0..<6).map { ideal[$0] - Double(Int(ideal[$0])) }
        var delta = n - alloc.reduce(0, +)
        while delta > 0 {
            let candidates = (0..<6).filter { alloc[$0] < avail[$0] }
            guard let pick = candidates.max(by: { carry[$0] < carry[$1] }) else { break }
            alloc[pick] += 1
            carry[pick] -= 1    // 补过的先不再补
            delta -= 1
        }
        while delta < 0 {
            let candidates = (0..<6).filter { alloc[$0] > 1 }
            guard let pick = candidates.min(by: { carry[$0] < carry[$1] }) else { break }
            alloc[pick] -= 1
            carry[pick] += 1    // 扣过的先不再扣
            delta += 1
        }
        // 频点实在不够（n 超过总频点数）：剩下的名额塞给覆盖八度最多的母带，
        // 段边界会被压到同一个频点上——只发生在荒谬的段数下。
        while delta > 0 {
            let pick = (0..<6).max { oct[$0] / Double(alloc[$0]) < oct[$1] / Double(alloc[$1]) }
            guard let pick else { break }
            alloc[pick] += 1
            delta -= 1
        }

        var edges: [Double] = []
        var parent: [Int] = []
        for p in 0..<6 {
            let lo = lows[p]
            let hi = base[p + 1]
            let b0 = firstBin(p)
            let b1 = lastBin(p)
            let m = max(1, min(alloc[p], max(1, b1 - b0)))
            // 段边界按对数等分再吸附到频点边界，保证每段至少一个频点。
            var bounds: [Int] = [b0]
            for j in 1..<m {
                let hz = lo * pow(hi / lo, Double(j) / Double(m))
                var b = Int(ceil(hz / binWidth - 1e-9))
                b = max(b, (bounds.last ?? b0) + 1)
                b = min(b, b1 - (m - j))
                bounds.append(b)
            }
            bounds.append(b1)
            for j in 0..<m {
                let e: Double = j == 0 ? lo : Double(bounds[j]) * binWidth
                edges.append(min(max(e, lo), hi))
                parent.append(p)
            }
        }
        edges.append(base[6])
        return BandLayout(edges: edges, parent: parent)
    }
}

nonisolated enum BandAnalyzer {
    /// 段数 -> (窗长, 跳步, 布局)。
    /// 6 段：1024/2048，前级与 Apple 逐位一致，tick 42.67 ms，结果在窗心 +10.7 ms。
    /// >6 段：窗长 2048（频点 23.4 Hz），跳步仍是 2048 —— tick 与所有时间常数不变，
    /// 只是窗心从 10.7 ms 挪到 21.3 ms（多占一档延迟）。再长的窗（4096）会让 tick
    /// 掉到 11.7 Hz，柱子反而变卡，所以封顶在 2048。
    /// 多段时的显示下限（6 段永远是 20 Hz，与 Apple 一致）。
    static let lowEdge: Double = 40

    static func plan(bandCount n: Int,
                            sampleRate: Double = 48000) -> (fft: Int, hop: Int, layout: BandLayout) {
        _ = sampleRate
        // 母带永远是 1024 点窗 / hop 2048（与 Apple 逐位一致），tick 时间戳因此固定。
        // 子段的细节比在 expand() 里用 2048 点窗另算，不影响这里的 tick 网格。
        if n <= 6 {
            return (1024, 2048, BandLayout(edges: BandLayout.appleEdges))
        }
        return (1024, 2048, BandLayout.make(count: n, binWidth: sampleRate / 4096.0, lowEdge: lowEdge))
    }

    /// 一帧 Hann 窗幅度谱。所有段数共用这一份结果——6 根、9 根、36 根都是同一个
    /// 频谱按各自边界求和，不存在第二个窗、也不存在两套量纲。
    /// 缩放沿用 Apple 的口径：vDSP 的实 FFT 输出是 numpy rfft 的 2 倍，先除 2 再套 2/(N/2)，
    /// 于是单音的峰高与窗长无关。
    static func magnitudes(samples: [Float], fftSize: Int) -> [Float] {
        guard fftSize >= 2, samples.count >= fftSize else { return [] }
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            window[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(fftSize))
        }

        let half = fftSize / 2
        let magScale = Float(2.0 / Double(half) / 2.0)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: fftSize)
        var mags = [Float](repeating: 0, count: half)

        samples.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
        }
        if magScale != 1 {
            // magScale 是 2 的幂，Float 乘法是精确的（指数移位），
            // 所以 6 段求和的数值与旧实现逐位相同。
            var s = magScale
            var scaled = [Float](repeating: 0, count: half)
            vDSP_vsmul(mags, 1, &s, &scaled, 1, vDSP_Length(half))
            return scaled
        }
        return mags
    }

    /// 把一帧幅度谱按布局求和，已乘 K = 2*sqrt(8/3)（与 lab/fe60.py 的 accs() 一致）。
    static func bands(magnitudes mags: [Float],
                      binWidth: Double,
                      layout: BandLayout,
                      cleanAssignment: Bool = false) -> [Double] {
        let count = layout.count
        guard count > 0, !mags.isEmpty else { return [] }
        let kFactor = 2.0 * (8.0 / 3.0).squareRoot()
        var row = [Double](repeating: 0, count: count)
        var band = 0
        for k in 0..<mags.count {
            let f = Double(k) * binWidth
            let m = Double(mags[k])
            if cleanAssignment {
                // 干净分箱：频点整份归到它中心所在的段（窄段只有 1-2 个频点时
                // 用下面那条规则会把这份能量几乎除没）。
                // 超出 [edges[0], edges[last]) 的频点直接丢掉——不然 10–24 kHz 全砸进
                // 最后一段，段数一多最右边那根会莫名高出一截。
                if f < layout.edges[0] || f >= layout.edges[count] { continue }
                while band + 1 < count && f >= layout.edges[band + 1] { band += 1 }
                row[band] += m
                continue
            }
            let lo = layout.edges[band]
            let hi = layout.edges[band + 1]
            if f < lo || f > hi {
                if band + 1 < count && f >= hi {
                    while band + 1 < count && f >= layout.edges[band + 1] { band += 1 }
                }
                row[band] += m / (hi - lo)
            } else {
                row[band] += m
            }
        }
        for b in 0..<count { row[b] *= kFactor }
        return row
    }

    /// 分箱：与 lab/fe60.py 的 accs() 逐位一致（6 段时可直接对比 A{i}.npy）。
    /// 返回 ticks × count，已乘 K = 2*sqrt(8/3)。
    static func analyze(samples: [Float],
                               sampleRate: Double,
                               layout: BandLayout,
                               fftSize: Int,
                               hop: Int,
                               cleanAssignment: Bool = false) -> [[Double]] {
        let count = layout.count
        guard count > 0, samples.count >= fftSize, fftSize >= 2 else { return [] }
        let binHz = sampleRate / Double(fftSize)
        let ticks = (samples.count - fftSize) / hop + 1
        var out = [[Double]](repeating: [Double](repeating: 0, count: count), count: ticks)
        for t in 0..<ticks {
            let window = Array(samples[(t * hop)..<(t * hop + fftSize)])
            let mags = magnitudes(samples: window, fftSize: fftSize)
            out[t] = bands(magnitudes: mags, binWidth: binHz, layout: layout,
                           cleanAssignment: cleanAssignment)
        }
        return out
    }

    /// 任意段数的**独立**分箱。
    ///
    /// 每一段只用自己的频点，然后把谱密度还原到母带带宽（乘 parentWidth/width）。
    /// 于是「平谱时这一段该显示多少」与母带完全一致——六段标定可以原样沿用；
    /// 而谱本身有起伏时每段各走各的，不会跟着母带一起动。
    ///
    /// 早先的做法是「母带包络 × 细节比」：n/6 根柱子共享同一个平顶，组内几乎一模一样、
    /// 组与组之间一个台阶。12 段两两一组、16 段三三一组、24 段四四一组就是这么来的——
    /// 那是 n/6 的结构，不是频谱的结构。
    static func expandIndependent(samples: [Float],
                                         layout: BandLayout,
                                         sampleRate: Double = 48000) -> (parent: [[Double]], acc: [[Double]]) {
        let p6 = BandLayout(edges: BandLayout.appleEdges)
        let parentAcc = analyze(samples: samples, sampleRate: sampleRate, layout: p6,
                                fftSize: 1024, hop: 2048)
        if layout.count == 6 { return (parentAcc, parentAcc) }
        // 4096 点窗的中心比 1024 点晚 (4096-1024)/2 = 1536 个样本。前面垫这么多零，
        // 细窗的第 k 个 tick 就和母带第 k 个 tick 落在同一时刻——否则多段模式整体晚 32 ms。
        let pad = (4096 - 1024) / 2
        var padded = [Float](repeating: 0, count: pad)
        padded.append(contentsOf: samples)
        var fine = density(samples: padded, layout: layout, sampleRate: sampleRate)
        // 4096 点窗与 1024 点窗之间差一个与「内容是噪声还是单音」有关的量纲常数：
        // 噪声类每段的绝对和会大 sqrt(N/1024) ≈ 2 倍，单音类基本不变。
        // 用一个全轨中位数对齐，逐段不单独归一（否则每组均值又被钉回母带）。
        let scale = windowScale(fine: fine, coarse: parentAcc, layout: layout)
        if scale > 0, abs(scale - 1) > 1e-6 {
            fine = fine.map { row in row.map { $0 / scale } }
        }
        var acc = Array(fine.prefix(parentAcc.count))
        while acc.count < parentAcc.count {
            acc.append(acc.last ?? [Double](repeating: 0, count: layout.count))
        }
        return (parentAcc, acc)
    }

    /// 细窗（4096 点）下的逐段谱密度，已换算回母带带宽。
    static func density(samples: [Float],
                               layout: BandLayout,
                               sampleRate: Double = 48000,
                               fftSize: Int = 4096,
                               hop: Int = 2048) -> [[Double]] {
        let sub = analyze(samples: samples, sampleRate: sampleRate, layout: layout,
                          fftSize: fftSize, hop: hop, cleanAssignment: true)
        let scale = layout.densityScale
        return sub.map { row in
            var r = row
            for i in 0..<r.count { r[i] *= scale[i] }
            return r
        }
    }

    /// 两种窗长之间的量纲差：逐 tick 幅度是 1/sqrt(N) 还是 1 取决于内容是噪声还是单音，
    /// 所以取「细窗各段之和 / 粗窗同一组之和」在整轨上的中位数，作为**一个**常数。
    /// 不用逐段归一——那会把每组的平均重新钉回母带，组间台阶又回来了。
    static func windowScale(fine: [[Double]], coarse: [[Double]], layout: BandLayout) -> Double {
        let t = min(fine.count, coarse.count)
        guard t > 8 else { return 1 }
        var perParent = [Int](repeating: 0, count: 6)
        for s in 0..<layout.count { perParent[min(max(layout.parent[s], 0), 5)] += 1 }
        var ratios: [Double] = []
        ratios.reserveCapacity(t)
        for k in 0..<t {
            var sumByParent = [Double](repeating: 0, count: 6)
            for s in 0..<layout.count { sumByParent[min(max(layout.parent[s], 0), 5)] += fine[k][s] }
            var num = 0.0, den = 0.0
            for p in 0..<6 where coarse[k][p] > 1e-9 && perParent[p] > 0 {
                num += sumByParent[p] / Double(perParent[p])
                den += coarse[k][p]
            }
            if den > 1e-9 { ratios.append(num / den) }
        }
        guard !ratios.isEmpty else { return 1 }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    /// 一次性把音频文件读成 48 kHz 单声道 Float 样本。
    static func loadSamples(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil else { return nil }
        let ch = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData else { return nil }
        if ch == 1 { return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))) }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        for c in 0..<ch {
            let p = data[c]
            for i in 0..<mono.count { mono[i] += p[i] / Float(ch) }
        }
        return mono
    }
}
