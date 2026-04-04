//
//  CoverCandidateStripView.swift
//  myPlayer2
//
//  kmgccc_player - Cover Candidate Thumbnail Strip
//  Horizontal scrollable thumbnail list for manual cover selection
//

import SwiftUI
import AppKit

/// A horizontal scrollable strip of cover candidate thumbnails.
/// Shows resolution badge on each thumbnail and highlights the selected one.
struct CoverCandidateStripView: View {
    let candidates: [CoverCandidate]
    let selectedCandidate: CoverCandidate?
    let onSelect: (CoverCandidate) -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    // Thumbnail size - compact
    private let thumbnailSize: CGFloat = 60
    private let spacing: CGFloat = 8

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                ForEach(candidates) { candidate in
                    thumbnailView(for: candidate)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(height: thumbnailSize + 16) // Thumbnail + badge height
    }

    @ViewBuilder
    private func thumbnailView(for candidate: CoverCandidate) -> some View {
        let isSelected = selectedCandidate?.id == candidate.id

        ZStack(alignment: .bottomTrailing) {
            // Thumbnail image
            if let nsImage = NSImage(data: candidate.imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            // Selected border
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(themeStore.accentColor, lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Resolution badge
            resolutionBadge(candidate.resolutionLabel)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            onSelect(candidate)
        }
        .accessibilityLabel("Cover candidate \(candidate.resolutionLabel)")
        .accessibilityHint(isSelected ? "Selected" : "Tap to select")
    }

    @ViewBuilder
    private func resolutionBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(2)
    }
}

#Preview("Cover Candidate Strip") {
    let sampleData1 = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        .tiffRepresentation!
    let sampleData2 = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
        .tiffRepresentation!

    let candidates = [
        CoverCandidate(imageData: sampleData1, source: .sacad, sourceItemId: "test-1"),
        CoverCandidate(imageData: sampleData2, source: .netease, sourceItemId: "test-2"),
    ]

    CoverCandidateStripView(
        candidates: candidates,
        selectedCandidate: candidates.first,
        onSelect: { _ in }
    )
    .environmentObject(ThemeStore.shared)
}