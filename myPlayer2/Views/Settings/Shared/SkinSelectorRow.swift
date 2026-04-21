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
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let selectionAccentColor = FullscreenSelectionAccentStyle.adjustedAccentColor(
            from: themeStore.accentNSColor
        )

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: itemSpacing) {
                Color.clear.frame(width: edgePadding)

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

                Color.clear.frame(width: edgePadding)
            }
            .padding(.vertical, verticalPadding)
        }
        .mask(
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, Color.white],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 12)
                Rectangle()
                    .fill(Color.white)
                LinearGradient(
                    colors: [Color.white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 12)
            }
        )
    }
}
