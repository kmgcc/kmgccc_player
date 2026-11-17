//
//  SettingsSidebarView.swift
//  myPlayer2
//
//  kmgccc_player - Settings Sidebar Navigation View
//

import SwiftUI

/// Settings sidebar with category navigation.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    @Binding var searchText: String
    let results: [SettingsSearchEntry]
    let selectedResultID: String?
    let selectResult: (SettingsSearchEntry) -> Void
    @EnvironmentObject private var themeStore: ThemeStore
    private let sidebarItemHorizontalInset: CGFloat = 14

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            Text("设置")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)

            searchField
                .padding(.horizontal, sidebarItemHorizontalInset)
                .padding(.bottom, 10)

            if isSearching {
                searchResults
            } else {
                categoryList
            }
        }
        .background(Material.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)

            TextField("搜索设置", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit {
                    if let first = results.first { selectResult(first) }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(themeStore.appForegroundPalette.secondaryColor.opacity(0.1), in: Capsule())
    }

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            Text("没有找到设置")
                .font(.callout)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 20)
                .padding(.top, 10)
        } else {
            List(results) { result in
                Button {
                    selectResult(result)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title)
                            .font(.body)
                            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(result.category.title)
                            if let tabTitle = result.tabTitle {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(tabTitle)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(result.title)
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedResultID == result.id ? themeStore.selectionFill : Color.clear)
                        .padding(.horizontal, sidebarItemHorizontalInset)
                )
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var categoryList: some View {
        List(SettingsCategory.allCases) { category in
            Button {
                selection = category
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 20)
                            .foregroundStyle(
                                selection == category
                                    ? themeStore.accentColor
                                    : themeStore.appForegroundPalette.secondaryColor)

                    Text(category.title)
                        .font(.body)
                        .fontWeight(selection == category ? .medium : .regular)
                        .foregroundStyle(themeStore.appForegroundPalette.primaryColor)

                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            .listRowBackground(
                Capsule()
                    .fill(selection == category ? themeStore.selectionFill : Color.clear)
                    .padding(.horizontal, sidebarItemHorizontalInset)
            )
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}
