//
//  SkinSelectorRow.swift
//  myPlayer2
//
//  kmgccc_player - Horizontal scrolling skin card selector.
//

import SwiftUI

/// Maps a skin identifier to its minimal vector preview.
@ViewBuilder
func skinPreview(for id: String, isSelected: Bool, accentColor: Color) -> some View {
    switch id {
    case "coverLed":
        ClassicSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "appleStyle":
        AppleStyleSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "rotatingCover":
        RotatingSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "kmgccc.cassette":
        CassetteSkinPreview(isSelected: isSelected, accentColor: accentColor)
    case "fullscreen.coverGradientBlur":
        CoverGradientBlurSkinPreview(isSelected: isSelected, accentColor: accentColor)
    default:
        ClassicSkinPreview(isSelected: isSelected, accentColor: accentColor)
    }
}

/// Horizontal scrollable row of skin preview cards with edge fade masks.
struct SkinSelectorRow: View {
    let skins: [SkinOption]
    @Binding var selectedSkinID: String
    var cardSize: CGSize = CGSize(width: 104, height: 124)
    var previewSize: CGFloat = 80
    var cornerRadius: CGFloat = 12
    var titleFontSize: CGFloat = 11
    var itemSpacing: CGFloat = 10
    var edgePadding: CGFloat = 10
    var verticalPadding: CGFloat = 4
    var showsScrollButtons: Bool = false
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let selectionAccentColor = FullscreenSelectionAccentStyle.adjustedAccentColor(
            from: themeStore.accentNSColor
        )

        HorizontalFadeScrollContainer(
            spacing: itemSpacing,
            fadeWidth: 12,
            verticalPadding: verticalPadding,
            leadingScrollPadding: edgePadding,
            trailingScrollPadding: edgePadding,
            showsEdgeFade: true,
            showsScrollButtons: showsScrollButtons,
            scrollButtonLeadingInset: max(4, edgePadding - 4),
            scrollButtonTrailingInset: max(4, edgePadding - 4)
        ) {
            ForEach(skins) { skin in
                let selected = selectedSkinID == skin.id
                SkinPreviewCard(
                    title: skin.name,
                    isSelected: selected,
                    cardSize: cardSize,
                    previewSize: previewSize,
                    cornerRadius: cornerRadius,
                    titleFontSize: titleFontSize,
                    preview: {
                        skinPreview(
                            for: skin.id,
                            isSelected: selected,
                            accentColor: selectionAccentColor
                        )
                    },
                    action: { selectedSkinID = skin.id }
                )
            }
        }
    }
}
