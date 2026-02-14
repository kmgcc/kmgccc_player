//
//  BatchTrackEditSheet.swift
//  myPlayer2
//
//  Queue-based batch metadata + lyrics processing sheet.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BatchTrackEditSheet: View {

    private struct ProcessState {
        var edited = false
        var saved = false
        var skipped = false
        var saveError: String?
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @EnvironmentObject private var themeStore: ThemeStore

    let tracks: [Track]

    @State private var currentIndex = 0
    @State private var autoSearchToken = 0

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var lyricsText = ""
    @State private var artworkData: Data?
    @State private var lyricsTimeOffsetMs: Double = 0

    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false
    @State private var statusMessage: String?
    @State private var isSavingCurrent = false
    @State private var isLoadingDraft = false
    @State private var processStateByTrackID: [UUID: ProcessState] = [:]

    private let amllDbURL = URL(string: "https://github.com/amll-dev/amll-ttml-db")!
    private let ttmlToolURL = URL(string: "https://amll-ttml-tool.stevexmh.net/")!

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if tracks.isEmpty {
                emptyView
            } else {
                HStack(spacing: 0) {
                    queuePanel
                    Divider()
                    editorPanel
                    Divider()
                    amllPreviewPanel
                }
            }

            Divider()

            footerView
        }
        .frame(minWidth: 1320, minHeight: 880)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .onAppear {
            guard !tracks.isEmpty else { return }
            prepareTrack(at: 0, triggerAutoSearch: true)
        }
        .onChange(of: title) { _, _ in
            draftDidChange()
        }
        .onChange(of: artist) { _, _ in
            draftDidChange()
        }
        .onChange(of: album) { _, _ in
            draftDidChange()
        }
        .onChange(of: lyricsText) { _, _ in
            draftDidChange()
        }
        .onChange(of: artworkData) { _, _ in
            draftDidChange()
        }
        .onChange(of: lyricsTimeOffsetMs) { _, _ in
            draftDidChange()
        }
        .fileImporter(
            isPresented: $showingArtworkPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleArtworkImport(result)
        }
        .fileImporter(
            isPresented: $showingLyricsPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "lrc") ?? .plainText,
                UTType(filenameExtension: "ttml") ?? .xml,
                .plainText,
            ],
            allowsMultipleSelection: false
        ) { result in
            handleLyricsImport(result)
        }
    }

    private var currentTrack: Track? {
        guard tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("批量编辑歌曲信息")
                    .font(.title2)
                    .fontWeight(.bold)

                if let track = currentTrack {
                    Text(
                        "当前：\(currentIndex + 1)/\(tracks.count) · \(track.title) · \(displayArtist(track.artist)) · \(displayAlbum(track.album))"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isSavingCurrent {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("未传入批量处理歌曲")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queuePanel: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    queueRow(track: track, index: index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func queueRow(track: Track, index: Int) -> some View {
        let state = processStateByTrackID[track.id]
        let isCurrent = index == currentIndex
        let status = queueStatus(for: state, isCurrent: isCurrent)

        return Button {
            selectTrack(index)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                queueArtwork(track: track, index: index)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.subheadline)
                        .lineLimit(1)

                    Text(displayArtist(track.artist))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(displayAlbum(track.album))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(status.text)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(status.color.opacity(0.16))
                        .foregroundStyle(status.color)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCurrent ? themeStore.selectionFill : Color(nsColor: .controlBackgroundColor).opacity(0.22))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isCurrent ? themeStore.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func queueArtwork(track: Track, index: Int) -> some View {
        let rowArtworkData = index == currentIndex ? artworkData : track.artworkData

        return Group {
            if let data = rowArtworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var editorPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                lyricsSection
                metadataSection
                Color.clear.frame(height: 80)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("元数据", systemImage: "info.circle")
                .font(.headline)

            HStack(spacing: 14) {
                Group {
                    if let data = artworkData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Button("导入封面") {
                        showingArtworkPicker = true
                    }
                    .buttonStyle(.bordered)

                    if artworkData != nil {
                        Button("移除封面", role: .destructive) {
                            artworkData = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Spacer()
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("标题")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("艺人")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("艺人", text: $artist)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("专辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("专辑", text: $album)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("歌词导入 / 查找 / 预编辑", systemImage: "text.quote")
                    .font(.headline)

                Spacer()

                Button {
                    openURL(amllDbURL)
                } label: {
                    Label("AMLL DB", systemImage: "arrow.up.right.square")
                }
                .font(.caption)

                Button {
                    openURL(ttmlToolURL)
                } label: {
                    Label("TTML Tool", systemImage: "hammer.fill")
                }
                .font(.caption)

                Button("导入歌词文件") {
                    showingLyricsPicker = true
                }
                .font(.caption)
            }

            TextEditor(text: $lyricsText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

            Text("TTML 文本区仅用于快速核对/微调；主要操作建议在下方 LDDC 区域完成。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("歌词时间偏移")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.2f s", lyricsTimeOffsetMs / 1000.0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("重置") {
                        lyricsTimeOffsetMs = 0
                    }
                    .font(.caption)
                }

                Slider(value: $lyricsTimeOffsetMs, in: -5000...5000, step: 100)
            }

            Divider()

            if let track = currentTrack {
                LDDCSearchSection(
                    track: track,
                    layoutStyle: .split,
                    includeTranslationDefault: true,
                    autoSearchToken: autoSearchToken
                ) { ttml in
                    lyricsText = ttml
                    _ = saveCurrentTrack(
                        showFailureMessage: true,
                        markProcessedIfUnchanged: false,
                        reason: "LDDC 应用歌词"
                    )
                }
                .frame(minHeight: 600)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var amllPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AMLL 渲染预览")
                .font(.headline)

            Text("当前编辑歌曲的 AMLL 实际渲染效果")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.82))

                if currentTrack == nil {
                    Text("无可预览歌曲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    AMLLWebView()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .frame(width: 360)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("跳过本首") {
                skipCurrentTrack()
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty)

            Button("保存当前") {
                _ = saveCurrentTrack(
                    showFailureMessage: true,
                    markProcessedIfUnchanged: true,
                    reason: "手动保存"
                )
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty || isSavingCurrent)

            Button(currentIndex >= tracks.count - 1 ? "完成" : "下一首") {
                goNextTrack()
            }
            .buttonStyle(.borderedProminent)
            .disabled(tracks.isEmpty || isSavingCurrent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func prepareTrack(at index: Int, triggerAutoSearch: Bool) {
        guard tracks.indices.contains(index) else { return }

        currentIndex = index
        loadTrackDraft(from: tracks[index])
        playCurrentTrackForEditing(tracks[index])
        syncAMLLPreview(reason: "切换编辑歌曲", forceLyricsReload: true)

        if triggerAutoSearch {
            autoSearchToken += 1
        }
    }

    private func loadTrackDraft(from track: Track) {
        isLoadingDraft = true
        title = track.title
        artist = track.artist
        album = track.album
        lyricsText = track.lyricsText ?? track.ttmlLyricText ?? ""
        artworkData = track.artworkData
        lyricsTimeOffsetMs = track.lyricsTimeOffsetMs
        statusMessage = nil
        isLoadingDraft = false
    }

    private func draftDidChange() {
        guard !isLoadingDraft else { return }
        guard let track = currentTrack else { return }
        guard hasDraftChangesComparedToCurrentTrack() else { return }

        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.edited = true
        state.saved = false
        state.skipped = false
        state.saveError = nil
        processStateByTrackID[track.id] = state
    }

    private func finalizeCurrentTrackBeforeSwitch() -> Bool {
        saveCurrentTrack(
            showFailureMessage: true,
            markProcessedIfUnchanged: true,
            reason: "切换到下一首前自动保存"
        )
    }

    private func selectTrack(_ index: Int) {
        guard tracks.indices.contains(index), index != currentIndex else { return }
        guard finalizeCurrentTrackBeforeSwitch() else { return }
        prepareTrack(at: index, triggerAutoSearch: true)
    }

    private func goNextTrack() {
        if currentIndex >= tracks.count - 1 {
            guard finalizeCurrentTrackBeforeSwitch() else { return }
            dismiss()
            return
        }

        guard finalizeCurrentTrackBeforeSwitch() else { return }
        prepareTrack(at: currentIndex + 1, triggerAutoSearch: true)
    }

    private func skipCurrentTrack() {
        guard let track = currentTrack else { return }

        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.skipped = true
        state.saved = false
        state.saveError = nil
        processStateByTrackID[track.id] = state
        statusMessage = "已跳过：\(track.title)"

        if currentIndex < tracks.count - 1 {
            prepareTrack(at: currentIndex + 1, triggerAutoSearch: true)
        }
    }

    @discardableResult
    private func saveCurrentTrack(
        showFailureMessage: Bool,
        markProcessedIfUnchanged: Bool,
        reason: String
    ) -> Bool {
        guard let track = currentTrack else { return false }
        guard !isSavingCurrent else { return false }

        let hasChanges = hasDraftChangesComparedToCurrentTrack()
        if !hasChanges {
            if markProcessedIfUnchanged {
                markTrackCompleted(track: track, edited: false)
                statusMessage = "已完成：\(track.title)"
            }
            return true
        }

        isSavingCurrent = true
        defer { isSavingCurrent = false }

        track.title = title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        track.artist = artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        track.album = album.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : album
        track.artworkData = artworkData
        track.lyricsTimeOffsetMs = lyricsTimeOffsetMs

        let trimmedLyrics = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLyrics.isEmpty {
            track.lyricsText = nil
            track.ttmlLyricText = nil
        } else if trimmedLyrics.lowercased().contains("<tt") {
            track.ttmlLyricText = trimmedLyrics
            track.lyricsText = nil
        } else {
            track.lyricsText = trimmedLyrics
            track.ttmlLyricText = nil
        }

        do {
            try modelContext.save()
            LocalLibraryService.shared.writeSidecar(for: track)
            markTrackCompleted(track: track, edited: true)
            statusMessage = "已保存：\(track.title)"
            syncAMLLPreview(reason: reason, forceLyricsReload: true)
            return true
        } catch {
            var state = processStateByTrackID[track.id] ?? ProcessState()
            state.edited = true
            state.saved = false
            state.saveError = error.localizedDescription
            processStateByTrackID[track.id] = state

            if showFailureMessage {
                statusMessage = "保存失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    private func markTrackCompleted(track: Track, edited: Bool) {
        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.edited = state.edited || edited
        state.saved = true
        state.skipped = false
        state.saveError = nil
        processStateByTrackID[track.id] = state
    }

    private func hasDraftChangesComparedToCurrentTrack() -> Bool {
        guard let track = currentTrack else { return false }

        let savedTitle =
            title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        let savedArtist =
            artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        let savedAlbum =
            album.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : album

        if savedTitle != track.title { return true }
        if savedArtist != track.artist { return true }
        if savedAlbum != track.album { return true }
        if artworkData != track.artworkData { return true }
        if abs(lyricsTimeOffsetMs - track.lyricsTimeOffsetMs) > 0.000_1 { return true }

        let trimmedLyrics = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTTML: String? = {
            guard !trimmedLyrics.isEmpty else { return nil }
            return trimmedLyrics.lowercased().contains("<tt") ? trimmedLyrics : nil
        }()
        let targetPlainLyrics: String? = {
            guard !trimmedLyrics.isEmpty else { return nil }
            return trimmedLyrics.lowercased().contains("<tt") ? nil : trimmedLyrics
        }()

        if track.ttmlLyricText != targetTTML { return true }
        if track.lyricsText != targetPlainLyrics { return true }
        return false
    }

    private func handleArtworkImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            artworkData = try Data(contentsOf: url)
            _ = saveCurrentTrack(
                showFailureMessage: true,
                markProcessedIfUnchanged: false,
                reason: "导入封面后保存"
            )
        } catch {
            statusMessage = "导入封面失败：\(error.localizedDescription)"
        }
    }

    private func handleLyricsImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            lyricsText = try String(contentsOf: url, encoding: .utf8)
            _ = saveCurrentTrack(
                showFailureMessage: true,
                markProcessedIfUnchanged: false,
                reason: "导入歌词后保存"
            )
        } catch {
            statusMessage = "导入歌词失败：\(error.localizedDescription)"
        }
    }

    private func playCurrentTrackForEditing(_ track: Track) {
        playerVM.play(track: track)
    }

    private func syncAMLLPreview(reason: String, forceLyricsReload: Bool) {
        lyricsVM.ensureAMLLLoaded(
            track: currentTrack,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying,
            reason: reason,
            forceLyricsReload: forceLyricsReload
        )
    }

    private func queueStatus(for state: ProcessState?, isCurrent: Bool) -> (text: String, color: Color) {
        if isCurrent {
            return ("处理中", themeStore.accentColor)
        }
        guard let state else {
            return ("未处理", .secondary)
        }
        if state.skipped { return ("已跳过", .orange) }
        if state.saveError != nil { return ("保存失败", .red) }
        if state.saved { return ("已完成", .green) }
        if state.edited { return ("待保存", .yellow) }
        return ("未处理", .secondary)
    }

    private func displayArtist(_ raw: String) -> String {
        raw.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : raw
    }

    private func displayAlbum(_ raw: String) -> String {
        raw.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : raw
    }
}
