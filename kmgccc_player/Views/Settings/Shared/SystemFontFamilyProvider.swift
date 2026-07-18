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

    @Published private(set) var families: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false

    private var loadTask: Task<Void, Never>?

    private init() {}

    func loadIfNeeded() {
        guard !hasLoaded, loadTask == nil else { return }
        isLoading = true

        loadTask = Task {
            let loadedFamilies = await Task.detached(priority: .userInitiated) {
                let names = CTFontManagerCopyAvailableFontFamilyNames() as NSArray
                return names.compactMap { $0 as? String }.sorted()
            }.value

            families = loadedFamilies
            hasLoaded = true
            isLoading = false
            loadTask = nil
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
                    fontPickerRow(title: zhTitle, selection: $mainFontNameZh)
                    fontPickerRow(title: enTitle, selection: $mainFontNameEn)
                    fontPickerRow(title: translationTitle, selection: $translationFontName)
                }
            } else if fontProvider.isLoading {
                HStack(spacing: presentationStyle.scaled(8)) {
                    ProgressView()
                    Text("正在加载字体…")
                        .font(presentationStyle.captionFont)
                        .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: presentationStyle.scaled(10)) {
                    Text("字体列表尚未加载")
                        .font(presentationStyle.captionFont)
                        .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                    Spacer()
                    Button {
                        fontProvider.loadIfNeeded()
                    } label: {
                        Label("加载字体", systemImage: "textformat")
                            .font(presentationStyle.captionFont)
                            .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                    }
                }
            }
        }
    }

    private func fontPickerRow(
        title: LocalizedStringKey,
        selection: Binding<String>
    ) -> some View {
        HStack {
            Text(title)
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
            Spacer()
            Picker("", selection: selection) {
                ForEach(families(including: selection.wrappedValue), id: \.self) { family in
                    Text(family)
                        .font(.custom(family, size: presentationStyle.scaled(12)))
                        .tag(family)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(presentationStyle.rowLabelFont)
            .frame(width: presentationStyle.pickerWidth)
        }
    }

    private func families(including selectedFamily: String) -> [String] {
        guard !selectedFamily.isEmpty,
              !fontProvider.families.contains(selectedFamily)
        else {
            return fontProvider.families
        }
        return ([selectedFamily] + fontProvider.families).sorted()
    }
}
