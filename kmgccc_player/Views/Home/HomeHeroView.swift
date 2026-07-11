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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var appSettings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var coverImage: NSImage?
    @State private var artworkData: Data?
    @State private var heroBackdropImage: CGImage?
    @State private var heroCoverHoverBackdropImage: CGImage?
    @State private var heroArtworkChecksum: UInt64 = 0
    @State private var heroAnalysis: ArtworkColorAnalysis?
    @State private var isHovering = false
    @State private var isCoverHovering = false

    /// Local rendered-region polarity for this hero card's backdrop. Nil until
    /// the normal backdrop readability map has been scored; the foreground
    /// accessors then fall back to light ink (never the global dark fallback)
    /// per the readability plan. See `updateHeroLocalPolarity`.
    @State private var heroLocalPolarity: ArtworkForegroundPolarity?
    @State private var heroNormalReadabilityMap: RenderedBackdropReadabilityMap?
    @State private var heroHoverReadabilityMap: RenderedBackdropReadabilityMap?
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

    /// Foreground polarity actually applied to this hero card. The local
    /// rendered-region decision wins once the backdrop map is ready; until then
    /// light ink is used (never the global dark fallback), so a pending card
    /// does not flash dark text that the local pass would reject.
    private var heroResolvedPolarity: ArtworkForegroundPolarity {
        heroLocalPolarity ?? .lightOnDarkBackground
    }

    /// Readability profile variant for the resolved polarity. Both variants
    /// are precomputed in `readabilityCandidates`; selecting by polarity keeps
    /// colour, blend and alpha tiers in lockstep with one decision.
    private var heroResolvedReadabilityProfile: ArtworkReadabilityProfile {
        heroPalette.readabilityCandidates.profile(for: heroResolvedPolarity)
    }

    private var artworkTextPrimary: Color {
        ColorRenderingAdapter.makeSwiftUIColor(heroResolvedReadabilityProfile.foregroundPrimary)
    }

    private var artworkTextSecondary: Color {
        ColorRenderingAdapter.makeSwiftUIColor(heroResolvedReadabilityProfile.foregroundSecondary)
    }

    private var artworkDominantColor: NSColor {
        heroPalette.coverGradientDominant
    }

    @State private var trackToEdit: Track?

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
        baseHeroHeight + wideExpansion * 80
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
            coverHoverHitRegion
                .zIndex(2)
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
        .task(id: track.id) {
            await loadCoverImage()
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

    /// Three view-space sampling rectangles covering where the hero's
    /// foreground elements actually render (track info, action buttons, stats),
    /// expanded by `regionExpansionPoints` and mapped through the backdrop's
    /// leading-aligned aspect-fill into normalized image regions.
    private var heroReadabilityRegions: [NormalizedReadabilityRegion] {
        let viewSize = CGSize(width: containerWidth, height: heroHeight)
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
        let trackWidth = max(0, containerWidth - trackLeading - heroPadding)
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
        let statsRight = containerWidth - statsTrailingPadding
        let statsBottom = heroHeight - statsBottomPadding
        expandAndMap(CGRect(x: statsRight - statsWidth, y: statsBottom - statsHeight, width: statsWidth, height: statsHeight))

        return regions
    }

    /// View-space rects (pre-mapping) for the DEBUG overlay.
    private var heroReadabilityDebugViewRects: [CGRect] {
        let expansion = ColorSystemTokens.ReadabilityForeground.regionExpansionPoints
        let trackLeading = heroPadding + artworkLeadingWidth
        let trackWidth = max(0, containerWidth - trackLeading - heroPadding)
        let titleHeight = ceil(titleFontSize * 1.2) * 2
        let artistHeight = ceil(14 * 1.3)
        let trackHeight = titleHeight + 6 + artistHeight + 6 + descriptionScrollHeight + 4
        let actionBottom = heroHeight - (heroPadding + actionBottomPadding)
        let playWidth = heroButtonIconSize + 6 + 28 + 2 * heroButtonHorizontalPadding
        let actionWidth = playWidth + heroButtonHeight * 2 + 20
        let statsWidth: CGFloat = 112
        let statsHeight: CGFloat = 16
        let statsRight = containerWidth - statsTrailingPadding
        let statsBottom = heroHeight - statsBottomPadding
        return [
            CGRect(x: trackLeading, y: heroTopPadding, width: trackWidth, height: trackHeight),
            CGRect(x: trackLeading, y: actionBottom - heroButtonHeight, width: actionWidth, height: heroButtonHeight),
            CGRect(x: statsRight - statsWidth, y: statsBottom - statsHeight, width: statsWidth, height: statsHeight)
        ].map { $0.insetBy(dx: -expansion, dy: -expansion) }
    }

    /// Re-score the local polarity from the current backdrop maps, candidate
    /// colours and layout. No-op until the normal map exists; the hover map is
    /// folded in when it arrives (one further update, no animation).
    private func updateHeroLocalPolarity() {
        guard let normalMap = heroNormalReadabilityMap else { return }
        let regions = heroReadabilityRegions
        guard !regions.isEmpty else { return }
        var samples: [(map: RenderedBackdropReadabilityMap, regions: [NormalizedReadabilityRegion])] = [
            (normalMap, regions)
        ]
        if let hoverMap = heroHoverReadabilityMap {
            samples.append((hoverMap, regions))
        }
        let candidates = heroPalette.readabilityCandidates
        let decision = RenderedBackdropReadability.decide(
            darkForeground: candidates.darkOnLightBackground.foregroundPrimary,
            lightForeground: candidates.lightOnDarkBackground.foregroundPrimary,
            samples: samples
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

    private func heroBlurConfig(variant: HomeHeroBackdropVariant) -> CoverGradientBlurConfig {
        let isCoverHover = variant == .coverHover
        return CoverGradientBlurConfig(
            blurRadius: isCoverHover ? 560 : 240,
            colorOverlayOpacity: 0.46,
            transitionDuration: isCoverHover ? 0.28 : 0.35,
            edgeStripWidth: 3.0,
            blurStartRatio: 0.08,
            blurEndRatio: 0.9,
            overlayOffsetRatio: 0.0,
            blurCurveGamma: 5.0,
            overlayCurveGamma: 3.0,
            overlayStartRatioFromEdge: isCoverHover ? 0.0 : 0.28,
            edgeFillMode: .pixelStretch,
            blurMaskMode: isCoverHover ? .extensionOnly : .progressiveRamp,
            // Cover hover selects only the right-side extension so the square
            // cover area stays clean. Normal uses the same narrow strip as
            // fullscreen (30% of cover width) so the crisp cover region is wide.
            blurStartRatioFromEdge: isCoverHover ? 0.0 : 0.30,
            // Quadratic-dominant ramp matching the fullscreen skin: ~0 at the
            // strip's inner side, accelerating smoothly to a strong edge value
            // so the cover↔fill junction is well masked. Cover hover retains its
            // own curve unchanged.
            blurAlphaCoefficients: isCoverHover ? (0, 0.36, 0.38, 0.26) : (0, 0, 1.8, -0.8),
            // Continuous blur ramp across the fill (pixel-stretch) region:
            // 0 at the cover's right edge, easing up toward the right with no
            // hard seam at the cover→fill boundary. Matches fullscreen value.
            extensionFloorStrength: isCoverHover ? 0 : 0.2
        )
    }

    /// Width the background renderer draws the artwork at (scale-to-height).
    /// Used to push the text content past the visible cover art.
    /// Uses `heroHeight` so the square cover fills the full card height and
    /// text/buttons stay in the blurred extension region.
    private var artworkLeadingWidth: CGFloat {
        guard artworkData != nil else { return 0 }
        if let img = coverImage {
            return heroHeight * (img.size.width / max(1, img.size.height))
        }
        return heroHeight  // assume square while image is loading
    }

    /// Dynamic backdrop render target size matching the actual card aspect
    /// ratio so the cover area is not cropped by a mismatched fixed size.
    private var heroBackdropTargetSize: CGSize {
        let aspect = containerWidth / max(1, heroHeight)
        let targetHeight: CGFloat = 380
        let targetWidth = round(targetHeight * aspect)
        return CGSize(width: max(380, targetWidth), height: targetHeight)
    }

    @ViewBuilder
    private var backdropView: some View {
        if let heroBackdropImage {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    heroBackdropLayer(heroBackdropImage, geometry: geometry)

                    if let heroCoverHoverBackdropImage {
                        heroBackdropLayer(heroCoverHoverBackdropImage, geometry: geometry)
                            .opacity(isCoverHovering ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: 0.24), value: isCoverHovering)
                .animation(.easeInOut(duration: 0.24), value: heroCoverHoverBackdropImage != nil)
            }
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

    private func heroBackdropLayer(_ image: CGImage, geometry: GeometryProxy) -> some View {
        let imageAspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        return Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(imageAspect, contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
    }

    private var coverHoverSide: CGFloat {
        let side = artworkLeadingWidth > 0 ? artworkLeadingWidth : baseHeroHeight
        return min(heroHeight, max(1, side))
    }

    private var coverHoverHitRegion: some View {
        Color.clear
            .frame(width: coverHoverSide, height: coverHoverSide, alignment: .topLeading)
            .contentShape(Rectangle())
            .onHover { hovering in
                isCoverHovering = hovering
            }
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
                .foregroundStyle(heroPrimaryForeground)

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
                .foregroundStyle(heroSecondaryForeground)
            let albumTitle = LibraryNormalization.displayAlbum(track.album)
            if !LibraryNormalization.isUnknownAlbum(track.album), !albumTitle.isEmpty {
                Text(" \u{00B7} ")
                    .foregroundStyle(heroQuaternaryForeground)
                Text(albumTitle)
                    .foregroundStyle(heroSecondaryForeground)
            }
        }
        .font(.system(size: mode == .narrow ? 12 : 14, weight: .medium))
        .lineLimit(1)
    }

    @ViewBuilder
    private var descriptionLine: some View {
        let description = heroDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            ScrollView(.vertical, showsIndicators: true) {
                Text(description)
                    .font(.system(size: descriptionFontSize, weight: .ultraLight))
                    .lineSpacing(1.5)
                    .foregroundStyle(heroDescriptionForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: descriptionScrollHeight, alignment: .top)
            .scrollClipDisabled(false)
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
            let stats = PreferenceStatsService.shared.getStats(for: track.id)
            if stats.playCount > 0 {
                Text(" \u{00B7} ")
                Text("\(stats.playCount) 次播放")
            }
        }
        .font(.caption)
        .foregroundStyle(heroTertiaryForeground)
    }

    private var playButton: some View {
        Button {
            playHeroTrackInHomeQueue()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: heroButtonIconSize, weight: .semibold))
                Text("播放")
                    .font(.system(size: heroButtonTextSize, weight: .medium))
            }
            .foregroundStyle(heroButtonForeground)
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
                onEditTrack: { trackToEdit = $0 }
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

    private var heroSecondaryForeground: Color {
        artworkTextSecondary
    }

    private var heroDescriptionForeground: Color {
        artworkTextPrimary.opacity(0.80)
    }

    private var heroTertiaryForeground: Color {
        artworkTextPrimary.opacity(0.68)
    }

    private var heroQuaternaryForeground: Color {
        artworkTextPrimary.opacity(0.54)
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
        heroCoverHoverBackdropImage = nil
        heroArtworkChecksum = 0
        heroAnalysis = nil
        // New track: clear the previous track's local decision and maps so a
        // stale polarity cannot bleed into the new card.
        heroLocalPolarity = nil
        heroLocalDecision = nil
        heroNormalReadabilityMap = nil
        heroHoverReadabilityMap = nil
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
            targetPixelSize: CGSize(width: 480, height: 480)
        )
        async let backdropTask: HomeHeroBackdropArtifact? = renderHeroBackdrop(
            artworkData: data,
            checksum: checksum,
            variant: .normal
        )
        // Analyze locally so the hero's text/dominant colours track this card's
        // artwork, not the currently-playing track's ThemeStore palette.
        async let analysisTask: ArtworkColorAnalysis? = Task.detached(priority: .userInitiated) {
            ArtworkColorExtractor.analyze(from: data)
        }.value
        let image = await imageTask
        let backdrop = await backdropTask
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
        heroBackdropImage = backdrop?.image
        heroNormalReadabilityMap = backdrop?.readabilityMap ?? nil
        heroAnalysis = analysis
        // Image and map arrive together (built in one detached task), so score
        // immediately - no foreground-late-by-a-beat. The palette .onChange
        // re-scores once heroAnalysis propagates into the candidates.
        updateHeroLocalPolarity()

        let hoverBackdrop = await renderHeroBackdrop(
            artworkData: data,
            checksum: checksum,
            variant: .coverHover
        )
        guard heroArtworkChecksum == checksum else { return }
        heroCoverHoverBackdropImage = hoverBackdrop?.image
        heroHoverReadabilityMap = hoverBackdrop?.readabilityMap ?? nil
        // Fold the hover map in (one further update, animation disabled).
        updateHeroLocalPolarity()
    }

    private func renderHeroBackdrop(
        artworkData: Data,
        checksum: UInt64,
        variant: HomeHeroBackdropVariant
    ) async -> HomeHeroBackdropArtifact? {
        let config = heroBlurConfig(variant: variant)
        let targetSize = heroBackdropTargetSize
        let sizeTag = "\(Int(targetSize.width))x\(Int(targetSize.height))"
        // Bumped to v8: target size is now dynamic (card aspect ratio) so the
        // cache key includes the resolved size tag.
        let cacheKey = "\(checksum)-\(sizeTag)-home-hero-\(variant.cacheKey)-v8" as NSString

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

private enum HomeHeroBackdropVariant {
    case normal
    case coverHover

    var cacheKey: String {
        switch self {
        case .normal: return "normal"
        case .coverHover: return "cover-hover"
        }
    }
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
