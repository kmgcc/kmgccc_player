//
//  SystemFontFamilyProvider.swift
//  myPlayer2
//
//  kmgccc_player - Deferred system font family loading for lyrics settings
//

import Combine
import CoreText
import SwiftUI

@MainActor
final class SystemFontFamilyProvider: ObservableObject {
    static let shared = SystemFontFamilyProvider()

    @Published private(set) var families: [SystemFontFamily] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false

    private var loadTask: Task<Void, Never>?

    private init() {}

    func loadIfNeeded() {
        guard !hasLoaded, loadTask == nil else { return }
        isLoading = true

        loadTask = Task {
            let loadedFamilies = await Task.detached(priority: .userInitiated) {
                Self.loadFamilies()
            }.value

            families = loadedFamilies
            hasLoaded = true
            isLoading = false
            loadTask = nil
        }
    }

    nonisolated private static func loadFamilies() -> [SystemFontFamily] {
        autoreleasepool {
            let names = (CTFontManagerCopyAvailableFontFamilyNames() as NSArray)
                .compactMap { $0 as? String }
                .sorted()
            var aliases = Dictionary(uniqueKeysWithValues: names.map { ($0, Set([$0])) })
            var displayNames: [String: String] = [:]

            // Read descriptors, never instantiate the catalog's fonts. Only
            // strings leave this scope; selecting a font remains the sole path
            // that asks the lyrics renderer to load a different family.
            let collection = CTFontCollectionCreateFromAvailableFonts(nil)
            let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
            for descriptor in descriptors {
                guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                      aliases[family] != nil
                else { continue }

                for attribute in [kCTFontFamilyNameAttribute, kCTFontDisplayNameAttribute, kCTFontNameAttribute] {
                    if let name = CTFontDescriptorCopyAttribute(descriptor, attribute) as? String {
                        aliases[family, default: []].insert(name)
                    }
                }
                if let name = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontFamilyNameAttribute, nil) as? String {
                    aliases[family, default: []].insert(name)
                    displayNames[family] = name
                }
                if let name = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontDisplayNameAttribute, nil) as? String {
                    aliases[family, default: []].insert(name)
                }
            }

            return names.map { family in
                SystemFontFamily(
                    name: family,
                    displayName: displayNames[family],
                    aliases: (aliases[family] ?? []).sorted()
                )
            }
        }
    }
}

struct DeferredLyricsFontPickerRows: View {
    @Binding var mainFontNameZh: String
    @Binding var mainFontNameEn: String
    @Binding var translationFontName: String

    let zhTitle: LocalizedStringKey
    let enTitle: LocalizedStringKey
    let translationTitle: LocalizedStringKey

    @ObservedObject private var fontProvider = SystemFontFamilyProvider.shared
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        Group {
            if fontProvider.hasLoaded {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    fontSearchRow(title: zhTitle, selection: $mainFontNameZh)
                    fontSearchRow(title: enTitle, selection: $mainFontNameEn)
                    fontSearchRow(title: translationTitle, selection: $translationFontName)
                }
            } else {
                HStack(spacing: presentationStyle.scaled(8)) {
                    ProgressView()
                    Text("正在加载字体…")
                        .font(presentationStyle.captionFont)
                        .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Opening the lyrics settings is the signal to read the catalog once.
        // Only names are cached; no font instance is created for the picker.
        .onAppear {
            fontProvider.loadIfNeeded()
        }
    }

    private func fontSearchRow(
        title: LocalizedStringKey,
        selection: Binding<String>
    ) -> some View {
        HStack {
            Text(title)
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
            Spacer()
            LyricsFontSearchField(
                selection: selection,
                families: fontProvider.families,
                fontSize: presentationStyle.rowFontSize,
                textColor: presentationStyle.settingsPrimaryTextColor(appColors: appColors)
            )
            .accessibilityLabel(Text(title))
            .frame(width: presentationStyle.pickerWidth)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
