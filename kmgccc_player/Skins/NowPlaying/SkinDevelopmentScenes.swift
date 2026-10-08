#if DEBUG
import SwiftUI

/// Three different compositions demonstrate whole-player and fine-grained authoring.
enum SkinDevelopmentScenes {
    static var packages: [PackagedSkin] {
        [
            package(id: "development.lyrics", name: "Lyrics Scene", root: lyricsScene),
            package(id: "development.artwork", name: "Artwork Scene", root: artworkScene),
            package(id: "development.vertical", name: "Vertical Scene", root: verticalScene),
        ]
    }

    private static func package(id: String, name: String, root: SkinSceneNode) -> PackagedSkin {
        PackagedSkin(manifest: .init(
            descriptor: .init(id: id, name: name, detail: "Native scene example", systemImage: "square.grid.2x2",
                              audio: .init(supportsEmbeddedVisualizer: false, hasLedMeter: false)),
            scene: .init(root: root)
        ), origin: .bundled, renderer: nil)
    }

    private static func overlay(_ content: SkinSceneNode) -> SkinSceneNode {
        .init(id: "scene", content: .overlay(children: [
            .component("background", "native.background", layout: .init(fillsWidth: true, fillsHeight: true)), content,
        ]), layout: .init(fillsWidth: true, fillsHeight: true))
    }

    private static func lyrics(maximumWidth: Double? = nil, maximumHeight: Double? = nil) -> SkinSceneNode {
        .component("lyrics", "native.lyrics", values: [
            "topEdgeOpacity": .number(0), "bottomEdgeOpacity": .number(0),
            "topFadeRange": .number(0.12), "bottomFadeRange": .number(0.12),
        ], layout: .init(maximumWidth: maximumWidth, maximumHeight: maximumHeight, fillsWidth: true, fillsHeight: true))
    }

    /// Independent side capsules around custom transport, without the native centre capsule.
    private static var lyricsScene: SkinSceneNode {
        overlay(.init(id: "reading", content: .column(children: [
            .component("title", "native.trackInfo"), lyrics(),
            .init(id: "controls", content: .row(children: [
                .component("actions", "native.actionsCapsule", values: ["scale": .number(0.6)]),
                .component("transport", "native.transport"),
                .component("volume", "native.volumeCapsule", values: ["scale": .number(0.6)]),
            ], spacing: 12)),
            .component("progress", "native.progress", layout: .init(height: 20, maximumWidth: 760, fillsWidth: true)),
        ], spacing: 16), layout: .init(padding: 24, fillsWidth: true, fillsHeight: true)))
    }

    /// The recommended complete native player, including both animated side capsules.
    private static var artworkScene: SkinSceneNode {
        overlay(.init(id: "artwork", content: .column(children: [
            .component("cover", "native.artwork", layout: .init(maximumWidth: 680, maximumHeight: 480, fillsWidth: true, fillsHeight: true)),
            .component("title", "native.trackInfo"), lyrics(maximumWidth: 760, maximumHeight: 230),
            .component("mini", "native.miniPlayer", layout: .init(height: 80, maximumWidth: 1280, fillsWidth: true)),
        ], spacing: 20), layout: .init(padding: 24, fillsWidth: true, fillsHeight: true)))
    }

    /// Fine controls only. The App supplies exit, lyrics and Quick Panel in the corner.
    private static var fineControls: SkinSceneNode {
        .init(id: "fine-controls", content: .column(children: [
            .component("progress", "native.progress", layout: .init(height: 20, maximumWidth: 480, fillsWidth: true)),
            .init(id: "buttons", content: .row(children: [
                .component("order", "native.playbackMode", values: ["scale": .number(0.8)]),
                .component("transport", "native.transport"),
                .component("volume", "native.volume", layout: .init(width: 76)),
            ], spacing: 20), layout: .init(height: 40)),
        ], spacing: 14), layout: .init(maximumWidth: 520, fillsWidth: true))
    }

    private static var verticalLyrics: SkinSceneNode {
        .component("lyrics", "native.lyrics", values: [
            "fontSize": .number(42), "translationFontSize": .number(18),
            "alignPosition": .number(0.38),
            "topEdgeOpacity": .number(0), "bottomEdgeOpacity": .number(0),
            "topFadeRange": .number(0.12), "bottomFadeRange": .number(0.16),
        ], layout: .init(maximumWidth: 680, fillsWidth: true, fillsHeight: true))
    }

    private static func verticalColumn(id: String, coverSize: Double?, spacing: Double, padding: Double) -> SkinSceneNode {
        let title = SkinSceneNode.component("title", "native.trackInfo", values: [
            "fontSize": .number(20), "artistFontSize": .number(14), "alignment": .text("center"),
        ])
        let header: SkinSceneNode
        if let coverSize {
            header = .init(id: "header", content: .column(children: [
                .component("cover", "native.artwork", values: ["cornerRadius": .number(16)],
                           layout: .init(width: coverSize, height: coverSize)), title,
            ], spacing: 16))
        } else {
            header = title
        }
        return .init(id: id, content: .column(children: [
            header, verticalLyrics, fineControls,
        ], spacing: spacing), layout: .init(maximumWidth: 760, padding: padding, fillsWidth: true, fillsHeight: true))
    }

    private static var verticalScene: SkinSceneNode {
        let wide = SkinSceneNode(id: "height-responsive", content: .adaptive(
            minimumWidth: 0, minimumHeight: 700,
            wide: verticalColumn(id: "tall", coverSize: 204, spacing: 24, padding: 32),
            compact: verticalColumn(id: "short", coverSize: 112, spacing: 20, padding: 24)
        ), layout: .init(fillsWidth: true, fillsHeight: true))
        let compact = verticalColumn(id: "compact", coverSize: nil, spacing: 20, padding: 24)
        return overlay(.init(id: "responsive", content: .adaptive(minimumWidth: 720, wide: wide, compact: compact),
                             layout: .init(fillsWidth: true, fillsHeight: true)))
    }
}
#endif
