//
//  TrackInfoEditorCore.swift
//  myPlayer2
//
//  Reusable song-info editor body for local tracks and external playback mappings.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func clearCurrentTextInputFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

struct TrackInfoEditorRawReference: Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkData: Data?
    var hasLyrics: Bool
}

struct TrackInfoEditorCore: View {
    enum Mode {
        case local
        case externalPlayback
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(CoverDownloadService.self) private var coverDownloadService
    @Environment(NetEaseCoverService.self) private var netEaseCoverService
    @EnvironmentObject private var themeStore: ThemeStore

    let mode: Mode
    let duration: Double
    let rawReference: TrackInfoEditorRawReference?
    let lyricsSearchTrack: Track?
    let allowsArtworkImport: Bool
    let allowsLyricsOffset: Bool
    let allowsDescriptionEditing: Bool
    let canSave: Bool
    let saveTitle: LocalizedStringKey
    let descriptionFallback: String?
    let showsDetailedMetadata: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    let onClearOverride: (() -> Void)?
    let onRestoreAutomatic: (() -> Void)?
    let onFetchMetadata: (() async -> Bool)?

    @Binding var title: String
    @Binding var artist: String
    @Binding var album: String
    @Binding var trackDescription: String
    @Binding var genreTagsText: String
    @Binding var language: String
    @Binding var labelOrCompany: String
    @Binding var releaseDateText: String
    @Binding var qqMusicSongMid: String
    @Binding var metadataSource: String
    @Binding var metadataFetchedAt: Date?
    @Binding var metadataConfidence: Double?
    @Binding var lyricsText: String
    @Binding var artworkData: Data?
    @Binding var lyricsTimeOffsetMs: Double

    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false
    @State private var isDetailedMetadataExpanded = false
    @State private var isMetadataLookupInFlight = false
    @State private var metadataLookupMessage: String?
    @State private var coverFetchTask: Task<Void, Never>?
    @State private var metadataFetchTask: Task<Void, Never>?
    @State private var artworkPreviewTask: Task<Void, Never>?
    @State private var artworkPreviewImage: TrackInfoArtworkPreviewImage?
    @State private var artworkPreviewSourceIdentity: String?
    @State private var coverCoordinator: CoverSearchCoordinator?

    private let amllDbURL = URL(string: "https://github.com/amll-dev/amll-ttml-db")!
    private let ttmlToolURL = URL(string: "https://amll-ttml-tool.stevexmh.net/")!

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if mode == .externalPlayback {
                        externalNoticeSection
                    }

                    if let rawReference {
                        rawReferenceSection(rawReference)
                        Divider()
                    }

                    artworkSection

                    Divider()

                    metadataSection

                    Divider()

                    lyricsSection

                    Color.clear.frame(height: 240)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    clearCurrentTextInputFocus()
                }
            }

            Divider()

            footerView
        }
        .frame(width: 550, height: 750)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .onAppear {
            let token = FirstUseHitchDiagnostics.begin(
                "TrackInfoEditorCore.onAppear",
                detail: "mode=\(mode)"
            )
            coverCoordinator = CoverSearchCoordinator(
                coverDownloadService: coverDownloadService,
                netEaseCoverService: netEaseCoverService
            )
            scheduleArtworkPreviewDecode(reason: "appear")
            let layoutToken = FirstUseHitchDiagnostics.begin(
                "TrackInfoEditorCore.initialSheetLayout",
                detail: "mode=\(mode)"
            )
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                FirstUseHitchDiagnostics.end(layoutToken)
            }
            FirstUseHitchDiagnostics.end(token)
        }
        .onDisappear {
            coverFetchTask?.cancel()
            coverFetchTask = nil
            metadataFetchTask?.cancel()
            metadataFetchTask = nil
            artworkPreviewTask?.cancel()
            artworkPreviewTask = nil
            coverCoordinator?.cancelSearch()
        }
        .onChange(of: coverCoordinator?.selectedForPreview) { _, newValue in
            if let candidate = newValue {
                artworkData = candidate.imageData
            }
        }
        .onChange(of: artworkData) { _, _ in
            scheduleArtworkPreviewDecode(reason: "artworkData changed")
        }
    }

    private var headerView: some View {
        HStack {
            Text(mode == .local ? "edit.track.title" : "编辑外部播放覆盖信息")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            GlassIconButton(
                systemImage: "xmark",
                size: GlassStyleTokens.headerControlHeight,
                iconSize: GlassStyleTokens.headerStandardIconSize,
                isPrimary: false,
                help: "关闭",
                surfaceVariant: .defaultToolbar
            ) {
                onCancel()
                dismiss()
            }
        }
        .padding()
    }

    private var externalNoticeSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(themeStore.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("这里编辑的是外部播放匹配和展示信息")
                    .font(.headline)
                Text("修改会保存为本 app 的匹配覆盖与解析缓存，不会回写外部播放源的原始元数据。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rawReferenceSection(_ reference: TrackInfoEditorRawReference) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("当前外部播放原始信息", systemImage: "music.note")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                TrackInfoStaticArtworkPreview(data: reference.artworkData, size: 72)

                VStack(alignment: .leading, spacing: 8) {
                    rawRow("标题", reference.title)
                    rawRow("艺人", reference.artist)
                    rawRow("专辑", reference.album)
                    rawRow("歌词", reference.hasLyrics ? "当前可用" : "当前不可用")
                }
            }
        }
    }

    private func rawRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(value.isEmpty ? "未提供" : value)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("edit.track.artwork", systemImage: "photo")
                .font(.headline)

            HStack(spacing: 16) {
                ZStack {
                    artworkPreview(size: 100)
                    if coverCoordinator?.isLoading == true {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    if allowsArtworkImport {
                        Button(LocalizedStringKey("edit.track.choose_image")) {
                            showingArtworkPicker = true
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                    }

                    Button(LocalizedStringKey("查找封面")) {
                        fetchCover()
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(coverCoordinator?.isLoading == true)

                    if artworkData != nil {
                        Button(LocalizedStringKey("edit.track.remove_artwork")) {
                            artworkData = nil
                            coverCoordinator?.clear()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .clipShape(Capsule())
                    }

                    if let error = coverCoordinator?.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let coordinator = coverCoordinator, coordinator.hasCandidates {
                    CoverCandidateStripView(
                        candidates: coordinator.candidates,
                        selectedCandidate: coordinator.selectedForPreview,
                        onSelect: { candidate in
                            coordinator.selectForPreview(candidate)
                            artworkData = candidate.imageData
                        }
                    )
                }
            }
        }
        .fileImporter(
            isPresented: $showingArtworkPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleArtworkImport(result)
        }
    }

    private func artworkPreview(size: CGFloat) -> some View {
        Group {
            if let artworkPreviewImage {
                Image(decorative: artworkPreviewImage.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(
            TrackInfoArtworkPreviewRenderProbe(
                identity: artworkPreviewImage?.identity ?? "placeholder",
                role: "editor"
            )
        )
    }

    private func scheduleArtworkPreviewDecode(reason: String) {
        artworkPreviewTask?.cancel()
        artworkPreviewTask = nil

        guard let data = artworkData, !data.isEmpty else {
            let token = FirstUseHitchDiagnostics.begin(
                "TrackInfoEditorCore.artworkPreviewClear",
                detail: reason
            )
            artworkPreviewImage = nil
            artworkPreviewSourceIdentity = nil
            FirstUseHitchDiagnostics.end(token)
            return
        }

        let identity = TrackInfoArtworkPreviewDecoder.lightweightIdentity(for: data)
        guard identity != artworkPreviewSourceIdentity else {
            Log.debug(
                "[TrackInfoEditorCore] skip artwork preview refresh reason=\(reason) identity=\(identity)",
                category: .perf
            )
            return
        }

        let playbackActive = playerVM.isPlaying
        let scheduleToken = FirstUseHitchDiagnostics.begin(
            "TrackInfoEditorCore.artworkPreviewSchedule",
            detail: "\(reason), bytes=\(data.count), identity=\(identity), playing=\(playbackActive)"
        )
        artworkPreviewSourceIdentity = identity
        artworkPreviewImage = nil
        FirstUseHitchDiagnostics.end(scheduleToken)

        artworkPreviewTask = Task.detached(priority: .utility) { [data, identity, playbackActive, reason] in
            let delayNs: UInt64 = playbackActive ? 300_000_000 : 0
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            guard !Task.isCancelled else { return }

            let decodeToken = FirstUseHitchDiagnostics.begin(
                "TrackInfoEditorCore.artworkPreviewDecode.background",
                detail: "\(reason), bytes=\(data.count), identity=\(identity), delayMs=\(delayNs / 1_000_000)"
            )
            let decoded = TrackInfoArtworkPreviewDecoder.decode(
                data: data,
                identity: identity,
                maxPixelSize: 320
            )
            FirstUseHitchDiagnostics.end(
                decodeToken,
                detail: decoded?.diagnosticSummary ?? "success=false"
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard artworkPreviewSourceIdentity == identity else {
                    Log.debug(
                        "[TrackInfoEditorCore] drop stale artwork preview identity=\(identity)",
                        category: .perf
                    )
                    return
                }

                let commitToken = FirstUseHitchDiagnostics.begin(
                    "TrackInfoEditorCore.artworkPreviewCommit",
                    detail: decoded?.commitSummary ?? "success=false, identity=\(identity)"
                )
                artworkPreviewImage = decoded?.image
                FirstUseHitchDiagnostics.end(commitToken)
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("edit.track.metadata", systemImage: "info.circle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                labeledField("edit.track.track_title", prompt: "edit.track.track_title", text: $title)
                labeledField("edit.track.artist", prompt: "edit.track.artist_name", text: $artist)
                labeledField("edit.track.album", prompt: "edit.track.album_name", text: $album)
                if allowsDescriptionEditing {
                    labeledEditor(
                        "edit.track.description",
                        prompt: "edit.track.description_placeholder",
                        text: $trackDescription
                    )

                    if let descriptionFallback,
                       trackDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !descriptionFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("来自专辑介绍")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(descriptionFallback)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if showsDetailedMetadata {
                    metadataLookupControl
                    detailedMetadataSection
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.duration")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(formatDuration(duration))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detailedMetadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isDetailedMetadataExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isDetailedMetadataExpanded ? 90 : 0))
                    Label("更多详细元数据", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if isDetailedMetadataExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    labeledField("流派 / 标签", prompt: "用逗号分隔", text: $genreTagsText)
                    labeledField("语言", prompt: "语言", text: $language)
                    labeledField("厂牌 / 公司", prompt: "厂牌或公司", text: $labelOrCompany)
                    labeledField("发行日期", prompt: "YYYY-MM-DD", text: $releaseDateText)

                    metadataReadonlySection
                }
                .padding(.top, 10)
            }
        }
    }

    private var metadataLookupControl: some View {
        HStack {
            Button {
                fetchMetadata()
            } label: {
                Label("查找元数据", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .disabled(isMetadataLookupInFlight)

            if isMetadataLookupInFlight {
                ProgressView()
                    .controlSize(.small)
            }

            if let metadataLookupMessage {
                Text(metadataLookupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metadataReadonlySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            readonlyMetadataRow("QQMusic Song MID", qqMusicSongMid)
            readonlyMetadataRow("来源", metadataSource)
            readonlyMetadataRow("获取时间", metadataFetchedAt.map(formatMetadataDate) ?? "")
            readonlyMetadataRow(
                "置信度",
                metadataConfidence.map { String(format: "%.2f", $0) } ?? ""
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func readonlyMetadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 118, alignment: .leading)
                .foregroundStyle(.tertiary)
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未记录" : value)
                .textSelection(.enabled)
        }
    }

    private func labeledField(
        _ label: LocalizedStringKey,
        prompt: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledEditor(
        _ label: LocalizedStringKey,
        prompt: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.body)
                    .lineSpacing(4)
                    .padding(8)
                    .frame(height: 132)
                    .scrollContentBackground(.hidden)

                if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .font(.body)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
            }
            .padding(.trailing, 18)
        }
    }

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("edit.track.lyrics", systemImage: "text.quote")
                    .font(.headline)

                Spacer()

                Button {
                    openURL(amllDbURL)
                } label: {
                    Label("AMLL DB", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)

                Button {
                    openURL(ttmlToolURL)
                } label: {
                    Label("TTML Tool", systemImage: "hammer.fill")
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)

                Button(LocalizedStringKey("edit.track.import_lyrics")) {
                    showingLyricsPicker = true
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)
            }

            Text(
                "AMLL DB 歌词库中的 TTML 专为 AMLL 组件设计，支持对唱歌词、背景歌词等高级特性，来自网络的转换歌词仅为歌词缺失情况下的备选。您也可以使用 AMLL TTML Tool 自己制作歌词使用或贡献到 AMLL DB。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $lyricsText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .padding(.trailing, 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

            Text("edit.track.paste_desc")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if allowsLyricsOffset {
                lyricsOffsetSection
            }

            Divider()
                .padding(.vertical, 8)

            lyricsSearchSection
        }
        .fileImporter(
            isPresented: $showingLyricsPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "ttml") ?? .xml,
                .plainText,
            ],
            allowsMultipleSelection: false
        ) { result in
            handleLyricsImport(result)
        }
    }

    private var lyricsOffsetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("edit.track.offset")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.2f s", lyricsTimeOffsetMs / 1000.0))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(LocalizedStringKey("edit.track.reset")) {
                    lyricsTimeOffsetMs = 0
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)
            }

            Slider(value: $lyricsTimeOffsetMs, in: -5000...5000, step: 100)

            Text(NSLocalizedString("edit.track.offset_desc", comment: ""))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var lyricsSearchSection: some View {
        if let lyricsSearchTrack {
            LDDCSearchSection(track: lyricsSearchTrack) { ttml in
                lyricsText = ttml
            }
        } else {
            LDDCSearchSection(
                title: title,
                artist: artist,
                album: album,
                duration: duration
            ) { ttml in
                lyricsText = ttml
            }
            .id("\(title)|\(artist)|\(album)|\(duration)")
        }
    }

    private var footerView: some View {
        HStack {
            Button(LocalizedStringKey("edit.track.cancel")) {
                onCancel()
                dismiss()
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .keyboardShortcut(.escape)

            if let onClearOverride {
                Button("清除覆盖", role: .destructive) {
                    onClearOverride()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }

            Spacer()

            Button(saveTitle) {
                onSave()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .keyboardShortcut(.return)
            .disabled(!canSave)
        }
        .padding()
    }

    private func fetchCover() {
        coverFetchTask?.cancel()
        coverCoordinator?.clear()

        coverFetchTask = Task {
            guard let coordinator = coverCoordinator else { return }
            await coordinator.search(
                artist: artist,
                album: album,
                title: title,
                duration: duration
            )
        }
    }

    private func fetchMetadata() {
        guard let onFetchMetadata else { return }
        metadataFetchTask?.cancel()
        isMetadataLookupInFlight = true
        metadataLookupMessage = nil

        metadataFetchTask = Task {
            let didApply = await onFetchMetadata()
            await MainActor.run {
                isMetadataLookupInFlight = false
                metadataLookupMessage = didApply ? "已补全缺失字段" : "没有可补全字段"
            }
        }
    }

    private func handleArtworkImport(_ result: Result<[URL], Error>) {
        guard allowsArtworkImport else { return }
        guard case .success(let urls) = result, let url = urls.first else { return }

        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) { @Sendable in
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try? Data(contentsOf: url)
            }.value
            if let data {
                artworkData = data
            }
        }
    }

    private func handleLyricsImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        Task { @MainActor in
            let text = await Task.detached(priority: .userInitiated) { @Sendable in
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try? String(contentsOf: url, encoding: .utf8)
            }.value
            if let text {
                lyricsText = text
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatMetadataDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private nonisolated final class TrackInfoArtworkPreviewImage: @unchecked Sendable {
    let identity: String
    let cgImage: CGImage
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int

    init(identity: String, cgImage: CGImage, sourcePixelWidth: Int, sourcePixelHeight: Int) {
        self.identity = identity
        self.cgImage = cgImage
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
    }
}

private nonisolated struct TrackInfoArtworkPreviewDecodeResult: Sendable {
    let image: TrackInfoArtworkPreviewImage
    let fullChecksum: UInt64
    let sourceMs: Double
    let metadataMs: Double
    let thumbnailMs: Double
    let checksumMs: Double

    var diagnosticSummary: String {
        "success=true, identity=\(image.identity), checksum=\(String(fullChecksum, radix: 16)), source=\(image.sourcePixelWidth)x\(image.sourcePixelHeight), thumbnail=\(image.cgImage.width)x\(image.cgImage.height), sourceMs=\(String(format: "%.1f", sourceMs)), metadataMs=\(String(format: "%.1f", metadataMs)), thumbnailMs=\(String(format: "%.1f", thumbnailMs)), checksumMs=\(String(format: "%.1f", checksumMs))"
    }

    var commitSummary: String {
        "success=true, identity=\(image.identity), thumbnail=\(image.cgImage.width)x\(image.cgImage.height)"
    }
}

private nonisolated enum TrackInfoArtworkPreviewDecoder {
    nonisolated static func lightweightIdentity(for data: Data) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        data.withUnsafeBytes { rawBuffer in
            let count = rawBuffer.count
            guard count > 0 else { return }

            func feed(_ byte: UInt8) {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }

            let edgeCount = min(128, count)
            for index in 0..<edgeCount {
                feed(rawBuffer[index])
            }

            if count > edgeCount {
                let suffixStart = max(edgeCount, count - edgeCount)
                for index in suffixStart..<count {
                    feed(rawBuffer[index])
                }
            }
        }
        return "\(data.count)-\(String(hash, radix: 16))"
    }

    nonisolated static func decode(
        data: Data,
        identity: String,
        maxPixelSize: Int
    ) -> TrackInfoArtworkPreviewDecodeResult? {
        let sourceStart = ProcessInfo.processInfo.systemUptime
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }
        let sourceMs = elapsedMs(since: sourceStart)

        let metadataStart = ProcessInfo.processInfo.systemUptime
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let metadataMs = elapsedMs(since: metadataStart)

        let thumbnailStart = ProcessInfo.processInfo.systemUptime
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let thumbnailMs = elapsedMs(since: thumbnailStart)

        let checksumStart = ProcessInfo.processInfo.systemUptime
        let checksum = ArtworkLoader.checksum(for: data)
        let checksumMs = elapsedMs(since: checksumStart)

        return TrackInfoArtworkPreviewDecodeResult(
            image: TrackInfoArtworkPreviewImage(
                identity: identity,
                cgImage: cgImage,
                sourcePixelWidth: sourceWidth,
                sourcePixelHeight: sourceHeight
            ),
            fullChecksum: checksum,
            sourceMs: sourceMs,
            metadataMs: metadataMs,
            thumbnailMs: thumbnailMs,
            checksumMs: checksumMs
        )
    }

    private nonisolated static func elapsedMs(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000
    }
}

private struct TrackInfoArtworkPreviewRenderProbe: View {
    let identity: String
    let role: String

    var body: some View {
        Color.clear
            .onAppear {
                Log.debug(
                    "[TrackInfoEditorCore] artwork preview view appear role=\(role) identity=\(identity)",
                    category: .perf
                )
            }
            .onChange(of: identity) { _, newValue in
                let token = FirstUseHitchDiagnostics.begin(
                    "TrackInfoEditorCore.artworkPreviewViewUpdate",
                    detail: "role=\(role), identity=\(newValue)"
                )
                FirstUseHitchDiagnostics.end(token)
            }
    }
}

private struct TrackInfoStaticArtworkPreview: View {
    let data: Data?
    let size: CGFloat

    @State private var image: TrackInfoArtworkPreviewImage?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: data.map { TrackInfoArtworkPreviewDecoder.lightweightIdentity(for: $0) } ?? "nil") {
            task?.cancel()
            guard let data, !data.isEmpty else {
                image = nil
                return
            }
            let identity = TrackInfoArtworkPreviewDecoder.lightweightIdentity(for: data)
            task = Task.detached(priority: .utility) {
                let decoded = TrackInfoArtworkPreviewDecoder.decode(
                    data: data,
                    identity: identity,
                    maxPixelSize: 160
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    image = decoded?.image
                }
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }
}
