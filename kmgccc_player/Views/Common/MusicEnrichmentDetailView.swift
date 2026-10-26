import PopupKit
import SwiftUI

/// The same reader is used for local playback and external listening.
struct MusicEnrichmentDetailView: View {
    let snapshot: MusicEnrichmentSnapshot
    let title: String
    let artist: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore

    private var fields: [String: MusicMetadataValue] { snapshot.attributes }

    private var rows: [(String, String)] {
        let keys: [(String, String)] = [
            ("albumName", "专辑"), ("albumArtistName", "专辑艺人"),
            ("composerName", "作曲"), ("releaseDate", "发行日期"),
            ("recordLabel", "厂牌"), ("copyright", "版权"),
            ("genreNames", "流派"), ("audioLocale", "语言"),
            ("discNumber", "碟序"), ("trackNumber", "曲序"),
            ("workName", "作品"), ("movementName", "乐章"),
            ("isrc", "ISRC"), ("upc", "UPC")
        ]
        var values = keys.compactMap { key, label -> (String, String)? in
            let text = fields[key]?.strings.joined(separator: "、") ?? ""
            return text.isEmpty ? nil : (label, text)
        }
        let audio = (fields["audioVariants"] ?? fields["audioTraits"])?.strings ?? []
        let audioNames = audio.map { value in
            switch value {
            case "lossless": "Lossless"
            case "hi-res-lossless": "Hi-Res Lossless"
            case "dolby-atmos": "Dolby Atmos"
            case "lossy-stereo": "Stereo"
            default: value
            }
        }
        if !audioNames.isEmpty { values.append(("目录音频版本", audioNames.joined(separator: "、"))) }
        if let songID = snapshot.record.query.appleSongID { values.append(("Apple Music", songID)) }
        if let storefront = snapshot.record.query.storefront { values.append(("地区", storefront.uppercased())) }
        return values
    }

    private var credits: [(String, String)] {
        guard case .array(let values) = fields["credits"] else { return [] }
        return values.compactMap { value in
            guard let record = value.dictionary, let name = record["name"]?.text else { return nil }
            return (record["role"]?.text ?? "参与人员", name)
        }
    }

    private var descriptionText: String? {
        let notes = fields["editorialNotes"]?.dictionary
        let text = notes?["standard"]?.text ?? notes?["short"]?.text
            ?? fields["artistBio"]?.text ?? fields["description"]?.text
        return text?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    var body: some View {
        AppPopupFrame(
            title: "音乐资料", systemImage: "music.note.list", onClose: { dismiss() },
            showsFooter: false, showsCloseButton: false,
            foreground: themeStore.appForegroundPalette, accent: themeStore.accentColor
        ) {
            AppPopupScrollRegion(height: AppPopupStyle().readerHeight) {
                VStack(alignment: .leading, spacing: AppPopupStyle().sectionSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.title3.weight(.medium))
                        Text(artist).foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            metadataRow(row.0, row.1)
                        }
                        ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                            metadataRow(credit.0, credit.1)
                        }
                    }
                    if let text = descriptionText, !text.isEmpty {
                        Text(text).lineSpacing(AppPopupStyle().bodyLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(sourceNames)
                        .font(.caption)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                }
                .font(.system(size: AppPopupStyle().bodySize))
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } actions: {
                Button("关闭") { dismiss() }
                    .buttonStyle(AppDialogGlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        } footer: {
            EmptyView()
        }
        .frame(width: AppPopupStyle().width)
    }

    private var sourceNames: String {
        let names = snapshot.record.results.map { result in
            switch result.source {
            case "appleWeb", "appleCache": "Apple Music"
            case "musicBrainz": "MusicBrainz"
            case "amllDB": "AMLL DB"
            default: result.source
            }
        }
        return Array(Set(names)).sorted().joined(separator: "、")
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
