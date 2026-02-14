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

    enum EntryFocus {
        case metadata
        case lyrics
    }

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
    let entryFocus: EntryFocus

    @State private var currentIndex = 0
    @State private var prioritizeLyricsSection = false
    @State private var autoSaveCurrent = true
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
    @State private var autoSaveTask: Task<Void, Never>?

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

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if prioritizeLyricsSection {
                                lyricsSection
                                metadataSection
                            } else {
                                metadataSection
                                lyricsSection
                            }

                            Color.clear.frame(height: 200)
                        }
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            footerView
        }
        .frame(minWidth: 1180, minHeight: 860)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .onAppear {
            prioritizeLyricsSection = entryFocus == .lyrics
            guard !tracks.isEmpty else { return }
            loadCurrentTrack()
            if entryFocus == .lyrics {
                autoSearchToken = 1
            }
        }
        .onDisappear {
            autoSaveTask?.cancel()
            autoSaveTask = nil
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
        .onChange(of: autoSaveCurrent) { _, enabled in
            if enabled && hasDraftChangesComparedToCurrentTrack() {
                scheduleAutoSave()
            }
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

    private var editedCount: Int {
        processStateByTrackID.values.filter { $0.edited }.count
    }

    private var savedCount: Int {
        processStateByTrackID.values.filter { $0.saved }.count
    }

    private var skippedCount: Int {
        processStateByTrackID.values.filter { $0.skipped }.count
    }

    private var remainingCount: Int {
        tracks.count - (savedCount + skippedCount)
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("批量处理")
                    .font(.title2)
                    .fontWeight(.bold)

                if let track = currentTrack {
                    Text(
                        "当前：\(currentIndex + 1)/\(tracks.count) · \(track.title) · \(track.artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : track.artist) · \(track.album.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : track.album)"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Text("没有可处理的歌曲")
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
        VStack(alignment: .leading, spacing: 12) {
            Text("待处理队列")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        queueRow(track: track, index: index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func queueRow(track: Track, index: Int) -> some View {
        let state = processStateByTrackID[track.id]
        let isCurrent = index == currentIndex

        return Button {
            goToTrack(index)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.subheadline)
                        .lineLimit(1)

                    Text(track.artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    queueStatusLabel(for: state)
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent ? themeStore.selectionFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func queueStatusLabel(for state: ProcessState?) -> some View {
        let tuple: (String, Color) = {
            guard let state else {
                return ("待处理", .secondary)
            }
            if state.skipped { return ("已跳过", .orange) }
            if state.saved { return ("已保存", .green) }
            if state.saveError != nil { return ("保存失败", .red) }
            if state.edited { return ("已编辑未保存", .yellow) }
            return ("待处理", .secondary)
        }()

        return Text(tuple.0)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tuple.1.opacity(0.16))
            .foregroundStyle(tuple.1)
            .clipShape(Capsule())
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("元数据", systemImage: "info.circle")
                .font(.headline)

            HStack(spacing: 16) {
                Group {
                    if let data = artworkData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, height: 110)
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

            HStack(spacing: 12) {
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
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

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
                    if autoSaveCurrent {
                        _ = saveCurrentTrack(showFailureMessage: false)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            Toggle("自动保存当前歌曲", isOn: $autoSaveCurrent)
                .toggleStyle(.switch)

            Divider()
                .frame(height: 18)

            Text("已编辑 \(editedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("已保存 \(savedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("剩余 \(remainingCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("跳过") {
                skipCurrentTrack()
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty)

            Button("保存当前") {
                _ = saveCurrentTrack(showFailureMessage: true)
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty || isSavingCurrent)

            Button(currentIndex >= tracks.count - 1 ? "完成" : "下一首") {
                nextTrack()
            }
            .buttonStyle(.borderedProminent)
            .disabled(tracks.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func loadCurrentTrack() {
        guard let track = currentTrack else { return }
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
        guard hasDraftChangesComparedToCurrentTrack() else { return }
        markCurrentEditedUnsaved()
        scheduleAutoSave()
    }

    private func scheduleAutoSave() {
        guard autoSaveCurrent else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                _ = saveCurrentTrack(showFailureMessage: false)
            }
        }
    }

    private func goToTrack(_ index: Int) {
        guard tracks.indices.contains(index), index != currentIndex else { return }
        finalizeCurrentTrackBeforeSwitch()
        currentIndex = index
        prioritizeLyricsSection = true
        autoSearchToken += 1
        loadCurrentTrack()
    }

    private func nextTrack() {
        if currentIndex >= tracks.count - 1 {
            finalizeCurrentTrackBeforeSwitch()
            dismiss()
            return
        }

        finalizeCurrentTrackBeforeSwitch()
        currentIndex += 1
        prioritizeLyricsSection = true
        autoSearchToken += 1
        loadCurrentTrack()
    }

    private func skipCurrentTrack() {
        guard let track = currentTrack else { return }
        autoSaveTask?.cancel()
        autoSaveTask = nil

        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.skipped = true
        state.saveError = nil
        state.saved = false
        processStateByTrackID[track.id] = state
        statusMessage = "已跳过：\(track.title)"

        if currentIndex < tracks.count - 1 {
            currentIndex += 1
            prioritizeLyricsSection = true
            autoSearchToken += 1
            loadCurrentTrack()
        }
    }

    private func finalizeCurrentTrackBeforeSwitch() {
        autoSaveTask?.cancel()
        autoSaveTask = nil

        if autoSaveCurrent {
            _ = saveCurrentTrack(showFailureMessage: false)
        } else if hasDraftChangesComparedToCurrentTrack() {
            markCurrentEditedUnsaved()
        }
    }

    @discardableResult
    private func saveCurrentTrack(showFailureMessage: Bool) -> Bool {
        guard let track = currentTrack else { return false }
        guard !isSavingCurrent else { return false }

        let hasChanges = hasDraftChangesComparedToCurrentTrack()
        if !hasChanges {
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

            if playerVM.currentTrack?.id == track.id {
                lyricsVM.ensureAMLLLoaded(
                    track: track,
                    currentTime: playerVM.currentTime,
                    isPlaying: playerVM.isPlaying,
                    reason: "batch track saved",
                    forceLyricsReload: true
                )
            }

            var state = processStateByTrackID[track.id] ?? ProcessState()
            state.edited = true
            state.saved = true
            state.skipped = false
            state.saveError = nil
            processStateByTrackID[track.id] = state
            statusMessage = "已保存：\(track.title)"
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

    private func markCurrentEditedUnsaved() {
        guard let track = currentTrack else { return }
        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.edited = true
        state.saved = false
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
            statusMessage = "封面已导入"
            if autoSaveCurrent {
                _ = saveCurrentTrack(showFailureMessage: false)
            }
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
            statusMessage = "歌词已导入"
            if autoSaveCurrent {
                _ = saveCurrentTrack(showFailureMessage: false)
            }
        } catch {
            statusMessage = "导入歌词失败：\(error.localizedDescription)"
        }
    }
}
