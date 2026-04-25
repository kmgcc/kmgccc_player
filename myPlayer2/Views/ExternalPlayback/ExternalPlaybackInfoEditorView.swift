//
//  ExternalPlaybackInfoEditorView.swift
//  myPlayer2
//
//  External playback wrapper for the shared song-info editor.
//

import SwiftUI

@MainActor
struct ExternalPlaybackInfoEditorView: View {
    let presentation: NowPlayingPresentation
    var onSaved: () -> Void

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var lyricsText: String
    @State private var artworkData: Data?
    @State private var lyricsTimeOffsetMs: Double = 0

    private let stableKey: String?
    private let rawTitle: String
    private let rawArtist: String
    private let rawAlbum: String
    private let initialTitle: String
    private let initialArtist: String
    private let initialAlbum: String
    private let initialLyricsText: String
    private let initialArtworkData: Data?

    init(presentation: NowPlayingPresentation, onSaved: @escaping () -> Void) {
        self.presentation = presentation
        self.onSaved = onSaved
        self.stableKey = presentation.externalStableKey
        self.rawTitle = presentation.externalRawTitle ?? presentation.title
        self.rawArtist = presentation.externalRawArtist ?? presentation.artist
        self.rawAlbum = presentation.externalRawAlbum ?? presentation.album ?? ""
        self.initialTitle = presentation.externalEffectiveTitle ?? presentation.externalRawTitle ?? presentation.title
        self.initialArtist = presentation.externalEffectiveArtist ?? presentation.externalRawArtist ?? presentation.artist
        self.initialAlbum = presentation.externalEffectiveAlbum ?? presentation.externalRawAlbum ?? presentation.album ?? ""
        // Prefer manually-locked lyrics if available; otherwise fall back to current presentation lyrics.
        let manualLyrics = stableKey.flatMap { ExternalPlaybackMetadataStore.shared.manualLyrics(for: $0) }
        self.initialLyricsText = manualLyrics ?? presentation.lyricsText ?? ""
        self.initialArtworkData = presentation.artworkData

        _title = State(initialValue: initialTitle)
        _artist = State(initialValue: initialArtist)
        _album = State(initialValue: initialAlbum)
        _lyricsText = State(initialValue: initialLyricsText)
        _artworkData = State(initialValue: initialArtworkData)
    }

    var body: some View {
        TrackInfoEditorCore(
            mode: .externalPlayback,
            duration: presentation.duration,
            rawReference: rawReference,
            lyricsSearchTrack: nil,
            allowsArtworkImport: true,
            allowsLyricsOffset: false,
            canSave: canSave,
            saveTitle: LocalizedStringKey("保存外部播放匹配"),
            onSave: {
                saveExternalEdits()
            },
            onCancel: {},
            onClearOverride: clearOverrideAction,
            onRestoreAutomatic: nil,
            title: $title,
            artist: $artist,
            album: $album,
            lyricsText: $lyricsText,
            artworkData: $artworkData,
            lyricsTimeOffsetMs: $lyricsTimeOffsetMs
        )
    }

    private var clearOverrideAction: (() -> Void)? {
        guard stableKey != nil else { return nil }
        return {
            clearOverride()
        }
    }

    private var rawReference: TrackInfoEditorRawReference {
        TrackInfoEditorRawReference(
            title: rawTitle,
            artist: rawArtist,
            album: rawAlbum,
            artworkData: presentation.artworkData,
            hasLyrics: !initialLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var canSave: Bool {
        guard stableKey != nil else { return false }
        return title != initialTitle
            || artist != initialArtist
            || album != initialAlbum
            || lyricsText != initialLyricsText
            || artworkData != initialArtworkData
    }

    private func saveExternalEdits() {
        guard let stableKey else { return }
        let existingOverride = ExternalPlaybackMetadataStore.shared.override(for: stableKey)
        let override = ExternalPlaybackMatchOverride(
            title: overrideValue(title, raw: rawTitle),
            artist: overrideValue(artist, raw: rawArtist),
            album: overrideValue(album, raw: rawAlbum),
            manuallySelectedLyrics: existingOverride?.manuallySelectedLyrics,
            manuallySelectedLyricsSource: existingOverride?.manuallySelectedLyricsSource,
            updatedAt: Date()
        )
        ExternalPlaybackMetadataStore.shared.saveOverride(override, for: stableKey)

        if let artworkData, artworkData != initialArtworkData {
            ExternalPlaybackMetadataStore.shared.storeNetworkArtwork(
                artworkData,
                for: stableKey,
                source: "manualOverride"
            )
        }

        if lyricsText != initialLyricsText {
            ExternalPlaybackMetadataStore.shared.saveManualLyrics(
                lyricsText,
                source: "manualOverride",
                for: stableKey
            )
        }

        onSaved()
    }

    private func clearOverride() {
        guard let stableKey else { return }
        ExternalPlaybackMetadataStore.shared.clearOverride(for: stableKey)
        onSaved()
    }

    private func overrideValue(_ value: String, raw: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != rawTrimmed else { return nil }
        return trimmed
    }
}
