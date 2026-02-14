//
//  ClassicLEDSkin.swift
//  myPlayer2
//
//  kmgccc_player - Classic LED Skin
//

import SwiftUI

struct ClassicLEDSkin: NowPlayingSkin {
    static let id: String = "coverLed"

    let id: String = ClassicLEDSkin.id
    let name: String = NSLocalizedString("skin.classic_led.name", comment: "")
    let detail: String = NSLocalizedString("skin.classic_led.detail", comment: "")
    let systemImage: String = "dot.radiowaves.left.and.right"

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(ClassicLEDArtwork(context: context))
    }

    var settingsView: AnyView? {
        AnyView(ClassicLEDSkinSettingsView())
    }
}

private struct ClassicLEDArtwork: View {
    let context: SkinContext
    @AppStorage("skin.classicLED.showLEDMeter") private var showLEDMeter: Bool = false

    var body: some View {
        let contentSize = context.contentSize
        let maxArtwork = min(contentSize.width * 0.5, contentSize.height * 0.5, 360)
        let artworkSize = max(180, maxArtwork)
        let ledSpacing: CGFloat = 32

        VStack(spacing: ledSpacing) {
            artworkView
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)

            if showLEDMeter {
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: 12,
                    spacing: 8,
                    pillTint: context.theme.artworkAccentColor
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.5), Color.blue.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.35))
                }
        }
    }
}

private struct ClassicLEDSkinSettingsView: View {
    @AppStorage("skin.classicLED.showLEDMeter") private var showLEDMeter: Bool = false

    var body: some View {
        Toggle(
            NSLocalizedString("skin.classic_led.show_led", comment: ""), isOn: $showLEDMeter
        )
        .toggleStyle(.switch)
    }
}
