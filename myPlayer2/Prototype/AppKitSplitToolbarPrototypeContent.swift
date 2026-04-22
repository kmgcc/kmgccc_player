//
//  AppKitSplitToolbarPrototypeContent.swift
//  myPlayer2
//
//  Placeholder content for the AppKit split-toolbar prototype window.
//

import SwiftUI

struct AppKitSplitToolbarPrototypeSidebarContent: View {
    @State private var selection = "Songs"
    private let items = [
        ("Songs", "music.note.list"),
        ("Albums", "square.stack"),
        ("Artists", "music.mic")
    ]

    var body: some View {
        List(selection: $selection) {
            ForEach(items, id: \.0) { item in
                Label(item.0, systemImage: item.1)
                    .tag(item.0)
            }
        }
        .listStyle(.sidebar)
    }
}

struct AppKitSplitToolbarPrototypeMainContent: View {
    private let rows = [
        "Track 01",
        "Track 02",
        "Track 03",
        "Track 04",
        "Track 05",
        "Track 06"
    ]

    var body: some View {
        List(rows, id: \.self) { row in
            HStack {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                Text(row)
                Spacer()
            }
        }
    }
}

struct AppKitSplitToolbarPrototypeLyricsContent: View {
    private let lines = Array(repeating: "Lyric line", count: 24)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(lines.indices, id: \.self) { index in
                    Text("\(lines[index]) \(index + 1)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
