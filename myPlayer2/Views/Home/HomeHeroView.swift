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

    private var artworkTextPrimary: Color {
        Color(nsColor: heroPalette.readableTextOnArtwork)
    }

    private var artworkTextSecondary: Color {
        Color(nsColor: heroPalette.readableTextOnArtwork.withAlphaComponent(0.78))
    }

    private var artworkDominantColor: NSColor {
        heroPalette.coverGradientDominant
    }

    @State private var trackToEdit: Track?

    private var baseHeroHeight: CGFloat {
        switch mode {
        case .wide:    return 320
        case .medium:  return 295
        case .compact: return 270
        case .narrow:  return 250
        }
    }

    private var heroHeight: CGFloat {
        baseHeroHeight + wideExpansion * 56
    }

    private var heroTopPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 36
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
            // Normal keeps the existing soft ramp; cover hover selects only
            // the right-side extension so the square cover area stays clean.
            blurStartRatioFromEdge: isCoverHover ? 0.0 : 0.42,
            // Keep the hero ramp earlier than fullscreen so the text area
            // resolves into a cleaner colour field at card height.
            blurAlphaCoefficients: isCoverHover ? (0, 0.36, 0.38, 0.26) : (0, 0.62, 0.26, 0.12)
        )
    }

    /// Width the background renderer draws the artwork at (scale-to-height).
    /// Used to push the text content past the visible cover art.
    private var artworkLeadingWidth: CGFloat {
        guard artworkData != nil else { return 0 }
        if let img = coverImage {
            return baseHeroHeight * (img.size.width / max(1, img.size.height))
        }
        return baseHeroHeight  // assume square while image is loading
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
                .fill(Color(nsColor: artworkDominantColor).opacity(colorScheme == .dark ? 0.42 : 0.26))
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
            inRandomQueueFrom: tracks,
            libraryQueueSource: .librarySelection("home")
        )
    }

    private func loadCoverImage() async {
        coverImage = nil
        artworkData = nil
        heroBackdropImage = nil
        heroCoverHoverBackdropImage = nil
        heroArtworkChecksum = 0
        heroAnalysis = nil
        let data = track.loadArtworkDataIfNeeded()
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
        async let backdropTask: CGImage? = renderHeroBackdrop(
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
        heroBackdropImage = backdrop
        heroAnalysis = analysis

        let hoverBackdrop = await renderHeroBackdrop(
            artworkData: data,
            checksum: checksum,
            variant: .coverHover
        )
        guard heroArtworkChecksum == checksum else { return }
        heroCoverHoverBackdropImage = hoverBackdrop
    }

    private func renderHeroBackdrop(
        artworkData: Data,
        checksum: UInt64,
        variant: HomeHeroBackdropVariant
    ) async -> CGImage? {
        let config = heroBlurConfig(variant: variant)
        let targetSize = CGSize(width: 1280, height: 380)
        let cacheKey = "\(checksum)-1280x380-home-hero-\(variant.cacheKey)-v5" as NSString

        if let cached = HomeHeroBackdropCache.shared.image(for: cacheKey) {
            return cached
        }

        let rendered = await Task.detached(priority: .utility) { () -> CGImage? in
            autoreleasepool {
                guard
                    let prepared = CoverGradientBlurRenderer.preparedArtworkImage(
                        artworkData: artworkData,
                        artworkImage: nil,
                        targetSize: targetSize
                    )
                else { return nil }

                return CoverGradientBlurRenderer.render(
                    artworkCGImage: prepared,
                    targetSize: targetSize,
                    dominantColor: nil,
                    config: config
                )
            }
        }.value

        if let rendered {
            HomeHeroBackdropCache.shared.setImage(rendered, for: cacheKey)
        }
        return rendered
    }
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

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, ImageBox>()

    private init() {
        cache.countLimit = 12
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for key: NSString) -> CGImage? {
        cache.object(forKey: key)?.image
    }

    func setImage(_ image: CGImage, for key: NSString) {
        let cost = max(1, image.bytesPerRow * image.height)
        cache.setObject(ImageBox(image), forKey: key, cost: cost)
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
