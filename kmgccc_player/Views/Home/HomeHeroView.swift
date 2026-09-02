//
//  HomeHeroView.swift
//  myPlayer2
//
//  Hero card for the Home page.
//  Blurred artwork backdrop with track info and play button.
//

import AppKit
import SwiftUI

struct HomeHeroView: View {
    let track: Track
    var containerWidth: CGFloat = 700
    var mode: HomeLayoutMode = .wide
    var onSwitchTrack: (() -> Void)?

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var appSettings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var coverImage: NSImage?
    @State private var artworkData: Data?
    @State private var heroBackdropImage: CGImage?
    @State private var heroBackdropLayoutSize: CGSize = .zero
    @State private var heroArtworkChecksum: UInt64 = 0
    @State private var heroAnalysis: ArtworkColorAnalysis?
    @State private var isHovering = false
    @State private var trackDeletionRequest: TrackDeletionConfirmationRequest?

    /// Local rendered-region polarity for this Hero's text and action icons.
    /// The same decision selects both the ordinary icon foreground and the
    /// adaptive Plus Lighter / Plus Darker text profile.
    @State private var heroLocalPolarity: ArtworkForegroundPolarity?
    @State private var heroNormalReadabilityMap: RenderedBackdropReadabilityMap?
    @State private var heroLocalDecision: LocalForegroundDecision?

    /// Cached hero palette. Invariant: equals `Self.makeHeroPalette(...)` for
    /// the most recent observed inputs. Recomputed only via the `.onChange`
    /// guards on `body`, NEVER inside body / computed properties — the
    /// factory is expensive (13+ semantic role colors per call) and the
    /// hero's foreground accessors are evaluated 10+ times per body run, so
    /// a per-body call would melt the CPU during live resize.
    @State private var heroPaletteCache: SemanticPalette = SemanticPaletteFactory.make(
        from: .neutralFallback,
        scheme: .light,
        userFallbackAccent: .systemBlue,
        useArtworkTint: false
    )

    /// Hero palette is derived from this hero card's own track artwork — it
    /// must NOT follow current playback when those differ. SemanticPaletteFactory
    /// is shared, but the analysis input is local.
    private var heroPalette: SemanticPalette { heroPaletteCache }

    private static func makeHeroPalette(
        analysis: ArtworkColorAnalysis?,
        scheme: ColorScheme,
        accentColor: Color,
        useArtworkTint: Bool
    ) -> SemanticPalette {
        SemanticPaletteFactory.make(
            from: analysis ?? .neutralFallback,
            scheme: scheme,
            userFallbackAccent: NSColor(accentColor),
            useArtworkTint: useArtworkTint && analysis != nil
        )
    }

    private func recomputeHeroPalette() {
        heroPaletteCache = Self.makeHeroPalette(
            analysis: heroAnalysis,
            scheme: colorScheme,
            accentColor: appSettings.accentColor,
            useArtworkTint: appSettings.globalArtworkTintEnabled
        )
    }

    /// Foreground polarity applied consistently to Hero text and action icons.
    /// Until the local rendered-region map is ready, light ink avoids an
    /// initial dark flash.
    private var heroResolvedPolarity: ArtworkForegroundPolarity {
        heroLocalPolarity ?? .lightOnDarkBackground
    }

    /// Readability profile variant for adaptive action icons. Both variants are
    /// precomputed in `readabilityCandidates`.
    private var heroResolvedReadabilityProfile: ArtworkReadabilityProfile {
        heroPalette.readabilityCandidates.profile(for: heroResolvedPolarity)
    }

    /// Hero text follows the same local polarity as the action icons, selecting
    /// Plus Lighter over dark regions and Plus Darker over light regions. The
    /// colours come from this Hero track's own palette rather than current
    /// playback.
    private var heroPlusBlendTextProfile: PlusBlendTextForegroundProfile {
        heroPalette.plusBlendText.profile(for: heroResolvedPolarity)
    }

    private var artworkTextPrimary: Color {
        ColorRenderingAdapter.makeSwiftUIColor(heroResolvedReadabilityProfile.foregroundPrimary)
    }

    private var artworkDominantColor: NSColor {
        heroPalette.coverGradientDominant
    }

    @State private var trackToEdit: Track?
    @State private var isShowingDescriptionReader = false
    @State private var isHoveringDescription = false

    init(
        track: Track,
        containerWidth: CGFloat = 700,
        mode: HomeLayoutMode = .wide,
        onSwitchTrack: (() -> Void)? = nil
    ) {
        self.track = track
        self.containerWidth = containerWidth
        self.mode = mode
        self.onSwitchTrack = onSwitchTrack
        _coverImage = State(
            initialValue: HomeArtworkMemoryStore.shared.cachedImage(
                for: HomeArtworkMemoryStore.heroCoverKey(for: track)
            )
        )
    }

    private var baseHeroHeight: CGFloat {
        switch mode {
        case .wide:    return 320
        case .medium:  return 295
        case .compact: return 270
        case .narrow:  return 250
        }
    }

    private var heroHeight: CGFloat {
        guard mode == .wide else { return baseHeroHeight }

        // Keep the extra-wide Hero visually balanced instead of letting the
        // banner become an increasingly thin strip. The wide layout starts at
        // the existing 320 pt floor, then follows the card width until a
        // desktop-friendly ceiling is reached.
        return min(max(containerWidth / 3.05, baseHeroHeight), 520)
    }

    private var heroTopPadding: CGFloat {
        switch mode {
        case .wide:          return 36 + wideExpansion * 8
        case .medium:        return 36
        case .compact:       return 28
        case .narrow:        return 24
        }
    }

    private var titleFontSize: CGFloat {
        let extra = wideExpansion * 5
        switch mode {
        case .wide:    return 31 + extra
        case .medium:  return 27
        case .compact: return 23
        case .narrow:  return 20
        }
    }

    private var wideExpansion: CGFloat {
        guard mode == .wide else { return 0 }
        return min(max((containerWidth - 920) / 520, 0), 1)
    }

    private var heroButtonHeight: CGFloat {
        switch mode {
        case .wide:    return 36 + wideExpansion * 8
        case .medium:  return 36
        case .compact: return 34
        case .narrow:  return 32
        }
    }

    private var heroButtonHorizontalPadding: CGFloat {
        switch mode {
        case .wide:    return 16 + wideExpansion * 4
        case .medium:  return 16
        case .compact: return 14
        case .narrow:  return 13
        }
    }

    private var heroButtonIconSize: CGFloat {
        switch mode {
        case .wide:    return 12 + wideExpansion * 2
        case .medium:  return 12
        case .compact: return 11
        case .narrow:  return 10.5
        }
    }

    private var heroButtonTextSize: CGFloat {
        switch mode {
        case .wide:    return 13 + wideExpansion * 1.5
        case .medium:  return 13
        case .compact: return 12
        case .narrow:  return 12
        }
    }

    private var descriptionLineCount: Int {
        switch mode {
        case .wide:    return wideExpansion > 0.55 ? 8 : 7
        case .medium:  return 7
        case .compact: return 5
        case .narrow:  return 5
        }
    }

    private var descriptionFontSize: CGFloat {
        mode == .narrow ? 11.5 : 13
    }

    // Cache by the two possible font sizes (11.5 narrow, 13 other) to avoid
    // allocating NSLayoutManager on every body evaluation.
    private static var lineHeightCache: [CGFloat: CGFloat] = [:]

    private var descriptionLineHeight: CGFloat {
        let size = descriptionFontSize
        if let cached = Self.lineHeightCache[size] { return cached }
        let height = NSLayoutManager().defaultLineHeight(
            for: NSFont.systemFont(ofSize: size, weight: .ultraLight)
        )
        Self.lineHeightCache[size] = height
        return height
    }

    private var descriptionScrollHeight: CGFloat {
        let lineSpacing: CGFloat = 1.5
        let lines = CGFloat(descriptionLineCount)
        return ceil(descriptionLineHeight * lines + lineSpacing * max(0, lines - 1) + 1)
    }

    private var heroPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 20
        case .compact:       return 16
        case .narrow:        return 14
        }
    }

    private var statsTrailingPadding: CGFloat {
        heroPadding + 6
    }

    private var statsBottomPadding: CGFloat {
        heroPadding + actionBottomPadding + 4
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdropView
                .allowsHitTesting(false)
            heroContent
                .zIndex(1)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(GlassStyleTokens.highlightGradient, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $isShowingDescriptionReader) {
            DetailDescriptionReaderSheet(
                title: "歌曲详情",
                systemImage: "music.note",
                subtitle: "\(track.title) · \(track.artist)",
                text: heroDescription,
                artworkImage: coverImage,
                artworkData: track.artworkData
            )
            .environmentObject(themeStore)
        }
        .trackDeletionConfirmation(item: $trackDeletionRequest) { tracks in
            Task {
                await libraryVM.deleteTracks(tracks)
            }
        }
        .task(id: track.id) {
            await loadCoverImage()
        }
        .task(id: heroBackdropRequestID) {
            await refreshHeroBackdropsForCurrentLayout()
        }
        .onAppear { recomputeHeroPalette() }
        .onChange(of: heroAnalysis) { _, _ in recomputeHeroPalette() }
        .onChange(of: colorScheme) { _, _ in recomputeHeroPalette() }
        .onChange(of: appSettings.accentColor) { _, _ in recomputeHeroPalette() }
        .onChange(of: appSettings.globalArtworkTintEnabled) { _, _ in recomputeHeroPalette() }
        // Local polarity depends on the rendered backdrop maps AND on the
        // candidate foreground colours (which live in the palette), plus the
        // layout that defines the sampling rectangles. None of these are
        // per-frame signals (playback time, spectrum, mouse), so re-scoring
        // here stays cheap.
        .onChange(of: heroPaletteCache) { _, _ in updateHeroLocalPolarity() }
        .onChange(of: containerWidth) { _, _ in updateHeroLocalPolarity() }
        .onChange(of: mode) { _, _ in updateHeroLocalPolarity() }
        .onChange(of: artworkLeadingWidth) { _, _ in updateHeroLocalPolarity() }
        .overlay { heroReadabilityDebugOverlay }
    }

    // MARK: - Local rendered-region readability

    /// Three view-space sampling rectangles covering where the Hero's adaptive
    /// foreground actually renders (track info, action buttons and stats),
    /// expanded by `regionExpansionPoints` and mapped through the backdrop's
    /// leading-aligned aspect-fill into normalized image regions.
    private var heroReadabilityRegions: [NormalizedReadabilityRegion] {
        let viewSize = CGSize(width: heroLayoutWidth, height: heroHeight)
        let imageSize = heroBackdropTargetSize
        let expansion = ColorSystemTokens.ReadabilityForeground.regionExpansionPoints
        var regions: [NormalizedReadabilityRegion] = []

        func expandAndMap(_ rect: CGRect) {
            guard rect.width > 0, rect.height > 0 else { return }
            let expanded = rect.insetBy(dx: -expansion, dy: -expansion)
            if let mapped = AspectFillReadabilityMapping.map(
                viewRect: expanded,
                viewSize: viewSize,
                imageSize: imageSize,
                horizontalAlignment: .leading,
                verticalAlignment: .center
            ) {
                regions.append(mapped)
            }
        }

        // trackInfo: title (≤2 lines) + artist/album line + description scroll.
        let trackLeading = heroPadding + artworkLeadingWidth
        let trackWidth = max(0, heroLayoutWidth - trackLeading - heroPadding)
        let titleHeight = ceil(titleFontSize * 1.2) * 2
        let artistHeight = ceil(14 * 1.3)
        let trackHeight = titleHeight + 6 + artistHeight + 6 + descriptionScrollHeight + 4
        expandAndMap(CGRect(x: trackLeading, y: heroTopPadding, width: trackWidth, height: trackHeight))

        // actions: bottom-leading button group (play + more + switch).
        let actionBottom = heroHeight - (heroPadding + actionBottomPadding)
        let playWidth = heroButtonIconSize + 6 + 28 + 2 * heroButtonHorizontalPadding
        let actionWidth = playWidth + heroButtonHeight * 2 + 20
        expandAndMap(CGRect(x: trackLeading, y: actionBottom - heroButtonHeight, width: actionWidth, height: heroButtonHeight))

        // stats: bottom-trailing caption (duration + play count).
        let statsWidth: CGFloat = 112
        let statsHeight: CGFloat = 16
        let statsRight = heroLayoutWidth - statsTrailingPadding
        let statsBottom = heroHeight - statsBottomPadding
        expandAndMap(CGRect(x: statsRight - statsWidth, y: statsBottom - statsHeight, width: statsWidth, height: statsHeight))

        return regions
    }

    /// View-space rects (pre-mapping) for the DEBUG overlay.
    private var heroReadabilityDebugViewRects: [CGRect] {
        let expansion = ColorSystemTokens.ReadabilityForeground.regionExpansionPoints
        let trackLeading = heroPadding + artworkLeadingWidth
        let trackWidth = max(0, heroLayoutWidth - trackLeading - heroPadding)
        let titleHeight = ceil(titleFontSize * 1.2) * 2
        let artistHeight = ceil(14 * 1.3)
        let trackHeight = titleHeight + 6 + artistHeight + 6 + descriptionScrollHeight + 4
        let actionBottom = heroHeight - (heroPadding + actionBottomPadding)
        let playWidth = heroButtonIconSize + 6 + 28 + 2 * heroButtonHorizontalPadding
        let actionWidth = playWidth + heroButtonHeight * 2 + 20
        let statsWidth: CGFloat = 112
        let statsHeight: CGFloat = 16
        let statsRight = heroLayoutWidth - statsTrailingPadding
        let statsBottom = heroHeight - statsBottomPadding
        return [
            CGRect(x: trackLeading, y: heroTopPadding, width: trackWidth, height: trackHeight),
            CGRect(x: trackLeading, y: actionBottom - heroButtonHeight, width: actionWidth, height: heroButtonHeight),
            CGRect(x: statsRight - statsWidth, y: statsBottom - statsHeight, width: statsWidth, height: statsHeight)
        ].map { $0.insetBy(dx: -expansion, dy: -expansion) }
    }

    /// Re-score the local polarity from the current backdrop map, candidate
    /// colours and layout. No-op until the normal map exists.
    private func updateHeroLocalPolarity() {
        guard let normalMap = heroNormalReadabilityMap else { return }
        let regions = heroReadabilityRegions
        guard !regions.isEmpty else { return }
        let candidates = heroPalette.readabilityCandidates
        let decision = RenderedBackdropReadability.decide(
            darkForeground: candidates.darkOnLightBackground.foregroundPrimary,
            lightForeground: candidates.lightOnDarkBackground.foregroundPrimary,
            samples: [(normalMap, regions)]
        )
        heroLocalDecision = decision
        // Disable implicit animation so blend-mode/colour tiers don't
        // interpolate through a grey middle state on the switch.
        withTransaction(Transaction(animation: nil)) {
            heroLocalPolarity = decision.polarity
        }
    }

    @ViewBuilder
    private var heroReadabilityDebugOverlay: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["READABILITY_REGION_DEBUG"] == "1" {
            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(heroReadabilityDebugViewRects.enumerated()), id: \.offset) { _, rect in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.green.opacity(0.9), lineWidth: 1.5)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    let polarity = heroLocalPolarity?.rawValue ?? "pending(light)"
                    let src = heroLocalPolarity == nil ? "fallback-light" : "hero-local"
                    let darkC = heroLocalDecision?.darkForegroundRobustContrast ?? 0
                    let lightC = heroLocalDecision?.lightForegroundRobustContrast ?? 0
                    let n = heroLocalDecision?.reason.rawValue ?? "-"
                    Text("\(src) \(polarity)\ndark=\(String(format: "%.2f", darkC)) light=\(String(format: "%.2f", lightC))\n\(n) cs=\(String(heroArtworkChecksum & 0xFFFF, radix: 16))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(4)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(4)
                        .padding(6)
                }
            }
            .allowsHitTesting(false)
        }
        #endif
    }

    private var heroBlurConfig: CoverGradientBlurConfig {
        CoverGradientBlurConfig(
            blurRadius: 240,
            colorOverlayOpacity: 0.46,
            transitionDuration: 0.35,
            edgeStripWidth: 3.0,
            blurStartRatio: 0.08,
            blurEndRatio: 0.9,
            overlayOffsetRatio: 0.0,
            blurCurveGamma: 5.0,
            overlayCurveGamma: 3.0,
            overlayStartRatioFromEdge: 0.28,
            edgeFillMode: .pixelStretch,
            blurMaskMode: .progressiveRamp,
            // Keep the cover mostly crisp, then start the progressive ramp a
            // little inside its right edge and continue it through the
            // pixel-stretched extension.
            blurStartRatioFromEdge: 0.30,
            blurAlphaCoefficients: (0, 0, 1.8, -0.8),
            extensionFloorStrength: 0.2
        )
    }

    /// The Hero always reserves a square, full-height artwork column. This is
    /// intentionally independent of image load state and source pixel aspect
    /// ratio so text/buttons never slide left onto the cover while loading or
    /// during a wide-window resize.
    private var artworkLeadingWidth: CGFloat {
        heroHeight
    }

    /// Width of the card as laid out by SwiftUI. `containerWidth` is a
    /// quantized parent-layout hint; using the measured width here prevents a
    /// small mismatch from making the display-side aspect-fill crop the
    /// artwork vertically at particular window widths.
    private var heroLayoutWidth: CGFloat {
        heroBackdropLayoutSize.width > 1 ? heroBackdropLayoutSize.width : containerWidth
    }

    /// Dynamic backdrop render target size matching the actual card aspect
    /// ratio so the cover area is not cropped by a mismatched fixed size.
    private var heroBackdropTargetSize: CGSize {
        let aspect = heroLayoutWidth / max(1, heroHeight)
        let targetHeight: CGFloat = 380
        let targetWidth = round(targetHeight * aspect)
        return CGSize(width: max(1, targetWidth), height: targetHeight)
    }

    private func updateHeroBackdropLayoutSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - heroBackdropLayoutSize.width) > 0.5
                || abs(size.height - heroBackdropLayoutSize.height) > 0.5 else {
            return
        }
        heroBackdropLayoutSize = size
    }

    /// Changes when either the artwork or the rendered card aspect ratio
    /// changes. The matching task debounces live resize and replaces the
    /// existing composite only after a correctly sized render is ready.
    private var heroBackdropRequestID: String {
        let targetSize = heroBackdropTargetSize
        return "\(track.id)-\(heroArtworkChecksum)-\(Int(targetSize.width))x\(Int(targetSize.height))"
    }

    @ViewBuilder
    private var backdropView: some View {
        GeometryReader { geometry in
            Group {
                if let heroBackdropImage {
                    heroBackdropLayer(heroBackdropImage, geometry: geometry)
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            ColorRenderingAdapter.makeSwiftUIColor(artworkDominantColor)
                                .opacity(colorScheme == .dark ? 0.42 : 0.26)
                        )
                        .overlay(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(colorScheme == .dark ? 0.34 : 0.08),
                                    Color.black.opacity(colorScheme == .dark ? 0.16 : 0.02),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            .onAppear {
                updateHeroBackdropLayoutSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                updateHeroBackdropLayoutSize(newSize)
            }
        }
    }

    private func heroBackdropLayer(_ image: CGImage, geometry: GeometryProxy) -> some View {
        return Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.medium)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
    }

    private var heroContent: some View {
        ZStack(alignment: .topLeading) {
            trackInfoView
                .padding(.top, heroTopPadding)
                .padding(.leading, heroPadding + artworkLeadingWidth)
                .padding(.trailing, heroPadding)
                .padding(.bottom, heroPadding)
                .contentShape(Rectangle())
                .onTapGesture {
                    playHeroTrackInHomeQueue()
                }
                .zIndex(1)

            statsLine
                .padding(.trailing, statsTrailingPadding)
                .padding(.bottom, statsBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .zIndex(2)

            actionButtons
                .padding(.leading, heroPadding + artworkLeadingWidth)
                .padding(.bottom, heroPadding + actionBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(true)
                .zIndex(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var trackInfoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(track.title)
                .font(.system(size: titleFontSize, weight: .semibold))
                .tracking(0)
                .lineLimit(2)
                .foregroundStyle(heroPlusBlendTextProfile.primaryColor)
                .compositingGroup()
                .blendMode(heroPlusBlendTextProfile.blendMode)

            artistAlbumLine
            descriptionLine
        }
    }

    private var actionBottomPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 8
        case .compact:       return 6
        case .narrow:        return 4
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            playButton
            moreButton
            switchTrackButton
        }
    }

    @ViewBuilder
    private var artistAlbumLine: some View {
        HStack(spacing: 0) {
            Text(track.artist)
                .foregroundStyle(heroPlusBlendTextProfile.secondaryColor)
                .compositingGroup()
                .blendMode(heroPlusBlendTextProfile.blendMode)
            let albumTitle = LibraryNormalization.displayAlbum(track.album)
            if !LibraryNormalization.isUnknownAlbum(track.album), !albumTitle.isEmpty {
                Text(" \u{00B7} ")
                    .foregroundStyle(heroPlusBlendTextProfile.tertiaryColor)
                    .compositingGroup()
                    .blendMode(heroPlusBlendTextProfile.blendMode)
                Text(albumTitle)
                    .foregroundStyle(heroPlusBlendTextProfile.secondaryColor)
                    .compositingGroup()
                    .blendMode(heroPlusBlendTextProfile.blendMode)
            }
        }
        .font(.system(size: mode == .narrow ? 12 : 14, weight: .medium))
        .lineLimit(1)
    }

    @ViewBuilder
    private var descriptionLine: some View {
        let description = heroDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            Button {
                isShowingDescriptionReader = true
            } label: {
                AppKitFullTextScrollView(
                    text: description,
                    font: NSFont.systemFont(ofSize: descriptionFontSize, weight: .ultraLight),
                    textColor: NSColor(heroPlusBlendTextProfile.secondaryColor),
                    lineSpacing: 1.5,
                    showsVerticalScroller: false
                )
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: descriptionScrollHeight, alignment: .top)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHoveringDescription ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringDescription = hovering
            }
            .help("点击查看完整详情")
            .compositingGroup()
            .blendMode(heroPlusBlendTextProfile.blendMode)
            .clipped()
            .layoutPriority(1)
            .padding(.top, 4)
        }
    }

    private var heroDescription: String {
        let trackDescription = track.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trackDescription.isEmpty { return trackDescription }
        return libraryVM.albumEntries
            .first { $0.canonicalKey == track.albumGroupKey }?
            .description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @ViewBuilder
    private var statsLine: some View {
        HStack(spacing: 0) {
            Text(formattedDuration)
            let stats = libraryVM.preferenceStats(for: track.id)
            if stats.playCount > 0 {
                Text(" \u{00B7} ")
                Text("\(stats.playCount) 次播放")
            }
        }
        .font(.caption)
        .foregroundStyle(heroPlusBlendTextProfile.tertiaryColor)
        .compositingGroup()
        .blendMode(heroPlusBlendTextProfile.blendMode)
    }

    private var playButton: some View {
        Button {
            playHeroTrackInHomeQueue()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: heroButtonIconSize, weight: .semibold))
                    .foregroundStyle(heroButtonForeground)
                Text("播放")
                    .font(.system(size: heroButtonTextSize, weight: .medium))
                    .foregroundStyle(heroPlusBlendTextProfile.primaryColor)
                    .compositingGroup()
                    .blendMode(heroPlusBlendTextProfile.blendMode)
            }
            .padding(.horizontal, heroButtonHorizontalPadding)
            .frame(height: heroButtonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .homeHeroHeaderGlassCapsule(colorScheme: colorScheme)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var moreButton: some View {
        Menu {
            TrackActionMenuContent(
                track: track,
                selectedPlaylistID: nil,
                onPlay: {
                    playHeroTrackInHomeQueue()
                },
                onPlayNext: playbackCoordinator.canInsertTracksAfterCurrent
                    ? { playbackCoordinator.insertTracksAfterCurrent([track]) }
                    : nil,
                onEditTrack: { trackToEdit = $0 },
                onDeleteFromLibraryRequest: { track in
                    trackDeletionRequest = TrackDeletionConfirmationRequest(tracks: [track])
                }
            )
        } label: {
            ZStack {
                Circle()
                    .fill(Color.clear)

                HStack(spacing: max(2.5, heroButtonIconSize * 0.22)) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(heroButtonForeground)
                            .frame(
                                width: max(3.2, heroButtonIconSize * 0.34),
                                height: max(3.2, heroButtonIconSize * 0.34)
                            )
                    }
                }
                .frame(width: heroButtonHeight, height: heroButtonHeight, alignment: .center)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .frame(width: heroButtonHeight, height: heroButtonHeight, alignment: .center)
            .contentShape(Circle())
            .homeHeroHeaderGlassCircle(colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: heroButtonHeight, height: heroButtonHeight)
        .fixedSize()
        .tint(heroButtonForeground)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private var switchTrackButton: some View {
        if let onSwitchTrack {
            Button {
                onSwitchTrack()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: heroButtonIconSize, weight: .semibold))
                    .foregroundStyle(heroButtonForeground)
                    .frame(width: heroButtonHeight, height: heroButtonHeight, alignment: .center)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .homeHeroHeaderGlassCircle(colorScheme: colorScheme)
            .help("切换顶部横幅歌曲")
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    private var heroButtonForeground: Color {
        heroPrimaryForeground
    }

    private var heroPrimaryForeground: Color {
        artworkTextPrimary
    }

    private var formattedDuration: String {
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var homePlayableTracks: [Track] {
        libraryVM.allTracks.filter { $0.availability != .missing }
    }

    private func playHeroTrackInHomeQueue() {
        let tracks = homePlayableTracks
        guard !tracks.isEmpty else { return }
        playbackCoordinator.playTrack(
            track,
            inQueueFrom: tracks,
            libraryQueueSource: .librarySelection("home")
        )
    }

    private func loadCoverImage() async {
        coverImage = HomeArtworkMemoryStore.shared.cachedImage(
            for: HomeArtworkMemoryStore.heroCoverKey(for: track)
        )
        artworkData = nil
        heroBackdropImage = nil
        heroArtworkChecksum = 0
        heroAnalysis = nil
        // New track: clear the previous track's local decision and maps so a
        // stale polarity cannot bleed into the new card.
        heroLocalPolarity = nil
        heroLocalDecision = nil
        heroNormalReadabilityMap = nil
        let data = await track.loadArtworkDataOffMainIfNeeded()
        guard let data, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        artworkData = data
        heroArtworkChecksum = checksum
        let key = ArtworkLoader.cacheKey(
            trackID: track.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 480, height: 480)
        )
        async let imageTask = ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 480, height: 480),
            derivativeStore: cacheServices.artworkDerivativeStore
        )
        // Analyze locally so the hero's text/dominant colours track this card's
        // artwork, not the currently-playing track's ThemeStore palette.
        async let analysisTask: ArtworkColorAnalysis? = Task.detached(priority: .userInitiated) {
            ArtworkColorExtractor.analyze(from: data)
        }.value
        let image = await imageTask
        let analysis = await analysisTask
        // Guard against a stale completion from a previous track — only apply
        // the result if this hero card's artwork hasn't changed underneath us.
        guard heroArtworkChecksum == checksum else { return }
        coverImage = image
        if let image {
            HomeArtworkMemoryStore.shared.store(
                image,
                for: HomeArtworkMemoryStore.heroCoverKey(for: track)
            )
        }
        heroAnalysis = analysis
    }

    /// Regenerate the single composited cover + progressive-blur backdrop for
    /// the current card aspect ratio. A short debounce prevents detached Core
    /// Image renders from piling up during live resize; the old composite stays
    /// visible until the new one is ready, so there is no empty flash.
    private func refreshHeroBackdropsForCurrentLayout() async {
        guard
            heroArtworkChecksum != 0,
            let artworkData,
            !artworkData.isEmpty
        else { return }

        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        let checksum = heroArtworkChecksum
        let requestID = heroBackdropRequestID
        let targetSize = heroBackdropTargetSize
        let backdrop = await renderHeroBackdrop(
            artworkData: artworkData,
            checksum: checksum,
            targetSize: targetSize
        )
        guard
            !Task.isCancelled,
            heroArtworkChecksum == checksum,
            heroBackdropRequestID == requestID,
            let backdrop
        else { return }

        heroBackdropImage = backdrop.image
        heroNormalReadabilityMap = backdrop.readabilityMap
        updateHeroLocalPolarity()
    }

    private func renderHeroBackdrop(
        artworkData: Data,
        checksum: UInt64,
        targetSize: CGSize
    ) async -> HomeHeroBackdropArtifact? {
        let config = heroBlurConfig
        let sizeTag = "\(Int(targetSize.width))x\(Int(targetSize.height))"
        // Bumped to v9: the Hero now uses one normal progressive composite;
        // the old clear-cover hover variant must never be reused.
        let cacheKey = "\(checksum)-\(sizeTag)-home-hero-v9" as NSString

        if let cached = HomeHeroBackdropCache.shared.artifact(for: cacheKey) {
            return cached
        }

        let rendered = await Task.detached(priority: .utility) { () -> HomeHeroBackdropArtifact? in
            autoreleasepool {
                guard
                    let prepared = CoverGradientBlurRenderer.preparedArtworkImage(
                        artworkData: artworkData,
                        artworkImage: nil,
                        targetSize: targetSize
                    )
                else { return nil }

                guard let image = CoverGradientBlurRenderer.render(
                    artworkCGImage: prepared,
                    targetSize: targetSize,
                    dominantColor: nil,
                    config: config
                ) else { return nil }

                // Build the readability map from the final rendered image in
                // the same detached task - never on the main thread. A failed
                // map build (very rare) still yields the image; the local
                // polarity pass then falls back to light ink.
                let map = RenderedBackdropReadabilityMap.make(from: image)
                return HomeHeroBackdropArtifact(image: image, readabilityMap: map)
            }
        }.value

        if let rendered {
            HomeHeroBackdropCache.shared.setArtifact(rendered, for: cacheKey)
        }
        return rendered
    }
}

/// Rendered hero backdrop plus its precomputed readability map. Both are
/// produced in one detached task and cached together so the local polarity
/// pass has the map available the moment the image is displayed. `readabilityMap`
/// is optional only because `CGImage` -> luminance-map conversion could fail
/// on a degenerate image; the visual is still usable in that case.
private struct HomeHeroBackdropArtifact: Sendable {
    let image: CGImage
    let readabilityMap: RenderedBackdropReadabilityMap?
}

private final class HomeHeroBackdropCache {
    static let shared = HomeHeroBackdropCache()

    private final class ImageBox: NSObject {
        let image: CGImage
        let readabilityMap: RenderedBackdropReadabilityMap?

        init(_ image: CGImage, _ readabilityMap: RenderedBackdropReadabilityMap?) {
            self.image = image
            self.readabilityMap = readabilityMap
        }
    }

    private let cache = NSCache<NSString, ImageBox>()

    private init() {
        cache.countLimit = 12
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func artifact(for key: NSString) -> HomeHeroBackdropArtifact? {
        guard let box = cache.object(forKey: key) else { return nil }
        return HomeHeroBackdropArtifact(image: box.image, readabilityMap: box.readabilityMap)
    }

    func setArtifact(_ artifact: HomeHeroBackdropArtifact, for key: NSString) {
        let cost = max(1, artifact.image.bytesPerRow * artifact.image.height)
        cache.setObject(ImageBox(artifact.image, artifact.readabilityMap), forKey: key, cost: cost)
    }
}

private extension View {
    @ViewBuilder
    func homeHeroHeaderGlassCapsule(colorScheme: ColorScheme) -> some View {
        self.modifier(HomeHeroHeaderGlassModifier(shape: Capsule(), colorScheme: colorScheme))
    }

    @ViewBuilder
    func homeHeroHeaderGlassCircle(colorScheme: ColorScheme) -> some View {
        self.modifier(HomeHeroHeaderGlassModifier(shape: Circle(), colorScheme: colorScheme))
    }
}

private struct HomeHeroHeaderGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.black.opacity(colorScheme == .dark ? 0.16 : 0.06)))
            .glassEffect(.clear, in: shape)
            .overlay {
                shape
                    .strokeBorder(GlassStyleTokens.highlightGradient, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
    }
}
