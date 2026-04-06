//
//  LyricsPreviewCard.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Lyrics Preview Card Component
//

import SwiftUI

/// A preview card showing lyrics styling with configurable fonts and weights.
struct LyricsPreviewCard: View {
    let title: String
    let isDarkCard: Bool
    let mainWeight: Int
    let translationWeight: Int
    let mainFontNameZh: String
    let mainFontNameEn: String
    let translationFontName: String
    let mainFontSize: Double
    let translationFontSize: Double

    init(
        title: String,
        isDarkCard: Bool,
        mainWeight: Int,
        translationWeight: Int,
        mainFontNameZh: String = "PingFang SC",
        mainFontNameEn: String = "SF Pro Text",
        translationFontName: String = "SF Pro Text",
        mainFontSize: Double = 24.0,
        translationFontSize: Double = 14.0
    ) {
        self.title = title
        self.isDarkCard = isDarkCard
        self.mainWeight = mainWeight
        self.translationWeight = translationWeight
        self.mainFontNameZh = mainFontNameZh
        self.mainFontNameEn = mainFontNameEn
        self.translationFontName = translationFontName
        self.mainFontSize = mainFontSize
        self.translationFontSize = translationFontSize
    }

    private var backgroundColor: Color {
        isDarkCard ? Color(red: 0.18, green: 0.18, blue: 0.20) : .white
    }

    private var titleColor: Color {
        isDarkCard ? Color.white.opacity(0.78) : Color.black.opacity(0.65)
    }

    private var mainTextColor: Color {
        isDarkCard ? Color.white : Color.black
    }

    private var translationColor: Color {
        isDarkCard ? Color.white.opacity(0.72) : Color.black.opacity(0.62)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(titleColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("settings.lyrics.preview_zh")
                    .font(.custom(mainFontNameZh, size: CGFloat(mainFontSize)))
                    .fontWeight(fontWeight(mainWeight))
                    .foregroundStyle(mainTextColor)
                Text("settings.lyrics.preview_en")
                    .font(.custom(mainFontNameEn, size: CGFloat(mainFontSize)))
                    .fontWeight(fontWeight(mainWeight))
                    .foregroundStyle(mainTextColor)
            }

            Text("时光像河流入海")
                .font(.custom(translationFontName, size: CGFloat(translationFontSize)))
                .fontWeight(fontWeight(translationWeight))
                .foregroundStyle(translationColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDarkCard ? Color.white.opacity(0.08) : Color.black.opacity(0.10),
                    lineWidth: 1
                )
        )
    }

    private func fontWeight(_ weight: Int) -> Font.Weight {
        switch weight {
        case 100: return .ultraLight
        case 200: return .thin
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return .regular
        }
    }
}