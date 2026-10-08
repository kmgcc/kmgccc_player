import Foundation

extension SkinPackageManifest {
    private enum CodingKeys: String, CodingKey { case formatVersion, hostAPIVersion, version, descriptor, nativePreset, scene, parameters }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try keys.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        hostAPIVersion = try keys.decodeIfPresent(Int.self, forKey: .hostAPIVersion) ?? 1
        version = try keys.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        descriptor = try keys.decode(SkinDescriptor.self, forKey: .descriptor)
        nativePreset = try keys.decodeIfPresent(String.self, forKey: .nativePreset)
        scene = try keys.decodeIfPresent(SkinSceneDocument.self, forKey: .scene)
        parameters = try keys.decodeIfPresent([SkinParameterDefinition].self, forKey: .parameters) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(formatVersion, forKey: .formatVersion)
        try keys.encode(hostAPIVersion, forKey: .hostAPIVersion)
        try keys.encode(version, forKey: .version)
        try keys.encode(descriptor, forKey: .descriptor)
        try keys.encodeIfPresent(nativePreset, forKey: .nativePreset)
        try keys.encodeIfPresent(scene, forKey: .scene)
        if !parameters.isEmpty { try keys.encode(parameters, forKey: .parameters) }
    }
}

extension SkinDescriptor {
    private enum CodingKeys: String, CodingKey {
        case id, name, detail, systemImage, surfaces, presentation, audio, artwork
        case fullscreenTypography, fullscreenDimming, fullscreenOrder, legacy
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        id = try keys.decode(String.self, forKey: .id)
        name = try keys.decode(String.self, forKey: .name)
        detail = try keys.decodeIfPresent(String.self, forKey: .detail) ?? ""
        systemImage = try keys.decodeIfPresent(String.self, forKey: .systemImage) ?? "paintpalette"
        surfaces = try keys.decodeIfPresent(Set<SkinSurface>.self, forKey: .surfaces) ?? [.window, .fullscreen]
        presentation = try keys.decodeIfPresent(SkinPresentationPolicy.self, forKey: .presentation) ?? .init()
        audio = try keys.decodeIfPresent(SkinAudioDefaults.self, forKey: .audio) ?? .init()
        artwork = try keys.decodeIfPresent(SkinArtworkDefaults.self, forKey: .artwork) ?? .init()
        fullscreenTypography = try keys.decodeIfPresent(FullscreenLyricsTypography.self, forKey: .fullscreenTypography) ?? .defaultValue
        fullscreenDimming = try keys.decodeIfPresent(Double.self, forKey: .fullscreenDimming) ?? AppSettings.FullscreenDefaults.dimmingIntensity
        fullscreenOrder = try keys.decodeIfPresent(Int.self, forKey: .fullscreenOrder) ?? 500
        legacy = try keys.decodeIfPresent(SkinLegacySettings.self, forKey: .legacy)
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(id, forKey: .id)
        try keys.encode(name, forKey: .name)
        try keys.encode(detail, forKey: .detail)
        try keys.encode(systemImage, forKey: .systemImage)
        try keys.encode(surfaces, forKey: .surfaces)
        try keys.encode(presentation, forKey: .presentation)
        try keys.encode(audio, forKey: .audio)
        try keys.encode(artwork, forKey: .artwork)
        try keys.encode(fullscreenTypography, forKey: .fullscreenTypography)
        try keys.encode(fullscreenDimming, forKey: .fullscreenDimming)
        try keys.encode(fullscreenOrder, forKey: .fullscreenOrder)
        try keys.encodeIfPresent(legacy, forKey: .legacy)
    }
}

// Partial author overrides inherit current defaults for omitted fields.
extension SkinPresentationPolicy {
    private nonisolated enum CodingKeys: String, CodingKey { case windowBackgroundPlacement, backgroundOwner, backgroundDimming, artworkLayout, lyricsBackdrop, controlForeground, movesArtworkWithControls, artBackgroundResourceProfile }

    nonisolated init(from decoder: any Decoder) throws {
        self.init()
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        windowBackgroundPlacement = try keys.decodeIfPresent(WindowBackgroundPlacement.self, forKey: .windowBackgroundPlacement) ?? windowBackgroundPlacement
        backgroundOwner = try keys.decodeIfPresent(BackgroundOwner.self, forKey: .backgroundOwner) ?? backgroundOwner
        backgroundDimming = try keys.decodeIfPresent(BackgroundDimming.self, forKey: .backgroundDimming) ?? backgroundDimming
        artworkLayout = try keys.decodeIfPresent(ArtworkLayout.self, forKey: .artworkLayout) ?? artworkLayout
        lyricsBackdrop = try keys.decodeIfPresent(LyricsBackdrop.self, forKey: .lyricsBackdrop) ?? lyricsBackdrop
        controlForeground = try keys.decodeIfPresent(ControlForeground.self, forKey: .controlForeground) ?? controlForeground
        movesArtworkWithControls = try keys.decodeIfPresent(Bool.self, forKey: .movesArtworkWithControls) ?? movesArtworkWithControls
        artBackgroundResourceProfile = try keys.decodeIfPresent(ArtBackgroundResourceProfile.self, forKey: .artBackgroundResourceProfile) ?? artBackgroundResourceProfile
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(windowBackgroundPlacement, forKey: .windowBackgroundPlacement)
        try keys.encode(backgroundOwner, forKey: .backgroundOwner)
        try keys.encode(backgroundDimming, forKey: .backgroundDimming)
        try keys.encode(artworkLayout, forKey: .artworkLayout)
        try keys.encode(lyricsBackdrop, forKey: .lyricsBackdrop)
        try keys.encode(controlForeground, forKey: .controlForeground)
        try keys.encode(movesArtworkWithControls, forKey: .movesArtworkWithControls)
        try keys.encode(artBackgroundResourceProfile, forKey: .artBackgroundResourceProfile)
    }
}

// Partial author overrides inherit current defaults for omitted fields.
extension SkinAudioDefaults {
    private enum CodingKeys: String, CodingKey { case window, fullscreen, supportsEmbeddedVisualizer, supportsMiniPlayerVisualization, hasLedMeter }

    init(from decoder: any Decoder) throws {
        self.init()
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        window = try keys.decodeIfPresent(AudioVisualizationPlacement.self, forKey: .window) ?? window
        fullscreen = try keys.decodeIfPresent(AudioVisualizationPlacement.self, forKey: .fullscreen) ?? fullscreen
        supportsEmbeddedVisualizer = try keys.decodeIfPresent(Bool.self, forKey: .supportsEmbeddedVisualizer) ?? supportsEmbeddedVisualizer
        supportsMiniPlayerVisualization = try keys.decodeIfPresent(Bool.self, forKey: .supportsMiniPlayerVisualization) ?? supportsMiniPlayerVisualization
        hasLedMeter = try keys.decodeIfPresent(Bool.self, forKey: .hasLedMeter) ?? hasLedMeter
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(window, forKey: .window)
        try keys.encode(fullscreen, forKey: .fullscreen)
        try keys.encode(supportsEmbeddedVisualizer, forKey: .supportsEmbeddedVisualizer)
        try keys.encode(supportsMiniPlayerVisualization, forKey: .supportsMiniPlayerVisualization)
        try keys.encode(hasLedMeter, forKey: .hasLedMeter)
    }
}

// Partial author overrides inherit current defaults for omitted fields.
extension SkinArtworkDefaults {
    private enum CodingKeys: String, CodingKey { case scale, maximumScale }

    init(from decoder: any Decoder) throws {
        self.init()
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        scale = try keys.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        maximumScale = try keys.decodeIfPresent(Double.self, forKey: .maximumScale) ?? maximumScale
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(scale, forKey: .scale)
        try keys.encode(maximumScale, forKey: .maximumScale)
    }
}
