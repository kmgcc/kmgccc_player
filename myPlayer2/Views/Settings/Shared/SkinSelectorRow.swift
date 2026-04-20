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
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 10)

                ForEach(skins) { skin in
                    let selected = selectedSkinID == skin.id
                    SkinPreviewCard(
                        title: skin.name,
                        isSelected: selected,
                        preview: {
                            skinPreview(for: skin.id, isSelected: selected, accentColor: themeStore.accentColor)
                        },
                        action: { selectedSkinID = skin.id }
                    )
                }

                Color.clear.frame(width: 10)
            }
            .padding(.vertical, 4)
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
