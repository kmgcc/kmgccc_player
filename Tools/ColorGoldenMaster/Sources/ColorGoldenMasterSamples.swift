import Foundation

struct GoldenSample: Sendable {
    enum Source: Sendable {
        case realTrack(trackID: String)
        case realArtwork(
            trackID: String,
            artworkPath: String,
            expectedHash: UInt64,
            corpus: String
        )
        case synthetic(side: Int, regions: [SyntheticRegion])
    }

    let id: String
    let title: String
    let note: String
    let source: Source
}

struct GoldenSampleSection: Sendable {
    let id: String
    let title: String
    let samples: [GoldenSample]
}

struct SyntheticRegion: Sendable {
    let share: Double
    let rgba: (UInt8, UInt8, UInt8, UInt8)

    init(_ share: Double, _ rgba: (UInt8, UInt8, UInt8, UInt8)) {
        self.share = share
        self.rgba = rgba
    }
}

enum ColorGoldenMasterSamples {
    static let trackRoot = "/Users/kmg/Music/kmgccc_player Library/Tracks"

    static func sections() throws -> [GoldenSampleSection] {
        [
            GoldenSampleSection(
                id: "golden_gate",
                title: "Golden Gate",
                samples: realGoldenGate
            ),
            GoldenSampleSection(
                id: "extended_corpus",
                title: "Extended Corpus",
                samples: try ExtendedCorpusStore.loadSamples()
            ),
            GoldenSampleSection(
                id: "synthetic",
                title: "Synthetic",
                samples: synthetic
            ),
        ]
    }

    static func all() throws -> [GoldenSample] {
        try sections().flatMap(\.samples)
    }

    static let realGoldenGate: [GoldenSample] = [
        GoldenSample(
            id: "real.01-golden-gate-ultra-dark-low-light",
            title: "Golden Gate 2D98505B",
            note: "Very low light; protects current UltraDark behavior and dark art layering.",
            source: .realTrack(trackID: "2D98505B-13F0-4AD8-A400-825877E644D7")
        ),
        GoldenSample(
            id: "real.02-golden-gate-true-bw-green-regression",
            title: "Golden Gate A38FB168",
            note: "Near black/white cover; guards against invented saturated green in light BK.",
            source: .realTrack(trackID: "A38FB168-3239-45D5-99EF-C49CA9B422EB")
        ),
        GoldenSample(
            id: "real.03-golden-gate-green-black-avoid-pink",
            title: "Golden Gate F36B8650",
            note: "Green plus black cover; guards against pink accent/lyrics/BK drift.",
            source: .realTrack(trackID: "F36B8650-79F6-401C-AE78-DA4882FEF531")
        ),
        GoldenSample(
            id: "real.04-golden-gate-warm-brown-led",
            title: "Golden Gate 356BFBF2",
            note: "Yellow/brown/black/warm white; guards warm LED and tonal BK swatches.",
            source: .realTrack(trackID: "356BFBF2-C2EF-40C1-972F-5D815620E4BC")
        ),
        GoldenSample(
            id: "real.05-golden-gate-true-bw-shapes",
            title: "Golden Gate 669A3609",
            note: "True black/white cover; floating shapes should stay grayscale.",
            source: .realTrack(trackID: "669A3609-9186-4784-9940-DAB4FB433034")
        ),
        GoldenSample(
            id: "real.06-golden-gate-warm-paper",
            title: "Golden Gate CB1A6016",
            note: "Warm paper plus black; low color count must not imply true BW.",
            source: .realTrack(trackID: "CB1A6016-137D-41A7-900B-78E0366DA759")
        ),
        GoldenSample(
            id: "real.07-golden-gate-black-small-yellow-a",
            title: "Golden Gate 865739F0",
            note: "Black field with tiny yellow marks; guards salient extraction without overuse.",
            source: .realTrack(trackID: "865739F0-E134-46EA-95F0-E99253CBB828")
        ),
        GoldenSample(
            id: "real.08-golden-gate-black-small-yellow-b",
            title: "Golden Gate 5040282F",
            note: "Same-family black/yellow cover; guards stable behavior across same artwork set.",
            source: .realTrack(trackID: "5040282F-9B7D-4E76-8058-B6F097C30B87")
        ),
        GoldenSample(
            id: "real.09-golden-gate-black-small-yellow-control",
            title: "Golden Gate 6C07C019",
            note: "Known-good black/yellow control sample for tiny accent extraction.",
            source: .realTrack(trackID: "6C07C019-B2A4-49DA-AE7E-26E7520EF8B9")
        ),
        GoldenSample(
            id: "real.10-golden-gate-red-black-white",
            title: "Golden Gate 939A3984",
            note: "Red/black/white with few hue families; guards against over-rich shape color.",
            source: .realTrack(trackID: "939A3984-C83F-42BA-8CD6-5FB302EF6F11")
        ),
        GoldenSample(
            id: "real.11-golden-gate-blue-white-green",
            title: "Golden Gate 0EB5760B",
            note: "Blue/white with green evidence; guards green companion preservation.",
            source: .realTrack(trackID: "0EB5760B-BE9B-498B-9A1B-63107456CEC0")
        ),
        GoldenSample(
            id: "real.12-golden-gate-muted-rich-pastel",
            title: "Golden Gate 1C82169C",
            note: "Low-saturation but color-rich cover; guards against grey BK collapse.",
            source: .realTrack(trackID: "1C82169C-C07E-4913-B8DF-E37ACF256278")
        ),
        GoldenSample(
            id: "real.13-golden-gate-night-dot-circle-a",
            title: "Golden Gate 415428CB",
            note: "Night dot/circle saturation relation sample.",
            source: .realTrack(trackID: "415428CB-47E6-4872-99BE-6C7327BE83F5")
        ),
        GoldenSample(
            id: "real.14-golden-gate-night-dot-circle-b",
            title: "Golden Gate 18265890",
            note: "Night dot/circle saturation relation sample.",
            source: .realTrack(trackID: "18265890-BAB8-4C12-82ED-8615CD3A174D")
        ),
        GoldenSample(
            id: "real.15-golden-gate-night-dot-circle-c",
            title: "Golden Gate 8A6BC5C1",
            note: "Night dot/circle saturation relation sample.",
            source: .realTrack(trackID: "8A6BC5C1-0C6E-42A1-A579-9A5AF57E0890")
        ),
        GoldenSample(
            id: "real.16-golden-gate-black-warm-skin",
            title: "Golden Gate FF0BC1BB",
            note: "Almost black with small warm/skin tone; guards muted real hue evidence.",
            source: .realTrack(trackID: "FF0BC1BB-4A84-4FA0-B6B4-FE424849D610")
        ),
        GoldenSample(
            id: "real.17-golden-gate-light-shapes-mode-consistency",
            title: "Golden Gate 5E98E21E",
            note: "Non-BW cover where light-mode shapes previously greyed out.",
            source: .realTrack(trackID: "5E98E21E-A0E3-4251-9218-4BB72F1DD597")
        ),
        GoldenSample(
            id: "real.18-golden-gate-muted-pink-paper-blue",
            title: "Golden Gate BA69BF06",
            note: "Soft pink/paper/cool blue; guards pastel light shapes and dark BK color floor.",
            source: .realTrack(trackID: "BA69BF06-281D-4995-A23A-816CB81D56EC")
        ),
        GoldenSample(
            id: "real.19-golden-gate-muted-purple-blue",
            title: "Golden Gate 5067A67A",
            note: "Soft pink-purple/blue-purple; guards trusted hue in muted covers.",
            source: .realTrack(trackID: "5067A67A-0D43-4EF5-9F7E-29E706B6B85F")
        ),
    ]

    static let synthetic: [GoldenSample] = [
        GoldenSample(
            id: "synthetic.01-near-mono-light-gray",
            title: "Synthetic nearMono light gray",
            note: "Deterministic true nearMono light-cover sample.",
            source: .synthetic(side: 32, regions: [SyntheticRegion(1.0, (200, 200, 200, 255))])
        ),
        GoldenSample(
            id: "synthetic.02-ultra-dark-colored-navy",
            title: "Synthetic UltraDark colored navy",
            note: "UltraDark but chromatic sample.",
            source: .synthetic(side: 32, regions: [SyntheticRegion(1.0, (10, 25, 70, 255))])
        ),
        GoldenSample(
            id: "synthetic.03-ultra-dark-mono-black",
            title: "Synthetic UltraDark mono black",
            note: "UltraDark and nearMono sample.",
            source: .synthetic(side: 32, regions: [SyntheticRegion(1.0, (15, 15, 15, 255))])
        ),
        GoldenSample(
            id: "synthetic.04-black-micro-yellow",
            title: "Synthetic black micro yellow",
            note: "Black field with a micro high-saturation accent.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.992, (0, 0, 0, 255)),
                SyntheticRegion(0.008, (255, 210, 16, 255)),
            ])
        ),
        GoldenSample(
            id: "synthetic.05-warm-paper-black-ink",
            title: "Synthetic warm paper",
            note: "Low-saturation warm material with black ink.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.58, (170, 158, 137, 255)),
                SyntheticRegion(0.18, (92, 86, 76, 255)),
                SyntheticRegion(0.14, (22, 22, 20, 255)),
                SyntheticRegion(0.10, (206, 198, 176, 255)),
            ])
        ),
        GoldenSample(
            id: "synthetic.06-high-saturation-four-way",
            title: "Synthetic high saturation four-way",
            note: "Four strong hue families at equal area.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.25, (210, 35, 45, 255)),
                SyntheticRegion(0.25, (40, 180, 60, 255)),
                SyntheticRegion(0.25, (40, 80, 200, 255)),
                SyntheticRegion(0.25, (240, 200, 30, 255)),
            ])
        ),
        GoldenSample(
            id: "synthetic.07-single-hue-tonal-warm",
            title: "Synthetic single hue tonal warm",
            note: "Single warm hue family with distinct light/dark tonal anchors.",
            source: .synthetic(side: 64, regions: [
                SyntheticRegion(0.48, (204, 199, 174, 255)),
                SyntheticRegion(0.20, (106, 92, 74, 255)),
                SyntheticRegion(0.18, (242, 240, 234, 255)),
                SyntheticRegion(0.14, (22, 20, 18, 255)),
            ])
        ),
    ]
}
