//
//  PlaylistDetailSkeletonView.swift
//  myPlayer2
//
//  Skeleton loading placeholder for playlist and library detail pages.
//  Provides graceful visual continuity during page transitions instead of
//  abruptly flashing a raw progress indicator.
//

import AppKit
import MotionKit
import SwiftUI

struct PlaylistDetailSkeletonView: View {
    let showHeader: Bool

    @State private var isPulsing = false
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy

    init(showHeader: Bool = true) {
        self.showHeader = showHeader
    }

    private var placeholderColor: Color {
        Color.primary.opacity(0.08)
    }

    private var placeholderHighlightColor: Color {
        Color.primary.opacity(0.14)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                if showHeader {
                    headerSkeleton
                }

                rowsSkeleton
            }
            .padding(.top, showHeader ? 20 : 12)
            .padding(.horizontal, 24)
            .padding(.bottom, 64)
        }
        .allowsHitTesting(false)
        .opacity(isPulsing ? 0.42 : 0.85)
        .onAppear {
            let spec = motionTokens.phaseSpec(for: .emphasis, duration: 1.1, bounce: 0)
            if let animation = motionPolicy.animation(for: spec) {
                withAnimation(animation.repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }

    @ViewBuilder
    private var headerSkeleton: some View {
        HStack(alignment: .bottom, spacing: 24) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(placeholderHighlightColor)
                .frame(width: 180, height: 180)

            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(placeholderColor)
                    .frame(width: 56, height: 13)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(placeholderHighlightColor)
                    .frame(width: 220, height: 26)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(placeholderColor)
                    .frame(width: 140, height: 15)

                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(placeholderColor)
                        .frame(width: 90, height: 13)
                }

                Spacer().frame(height: 4)

                HStack(spacing: 12) {
                    Capsule(style: .continuous)
                        .fill(placeholderHighlightColor)
                        .frame(width: 92, height: 32)

                    Circle()
                        .fill(placeholderColor)
                        .frame(width: 32, height: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var rowsSkeleton: some View {
        VStack(spacing: 8) {
            ForEach(0..<10, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(placeholderColor)
                        .frame(width: 16, height: 12)

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(placeholderHighlightColor)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(placeholderHighlightColor)
                            .frame(width: titleWidth(for: index), height: 13)

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(placeholderColor)
                            .frame(width: artistWidth(for: index), height: 11)
                    }

                    Spacer()

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(placeholderColor)
                        .frame(width: 34, height: 11)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            }
        }
    }

    private func titleWidth(for index: Int) -> CGFloat {
        let pattern: [CGFloat] = [180, 140, 220, 160, 190, 130, 210, 170, 150, 200]
        return pattern[index % pattern.count]
    }

    private func artistWidth(for index: Int) -> CGFloat {
        let pattern: [CGFloat] = [100, 80, 120, 90, 110, 85, 130, 95, 80, 115]
        return pattern[index % pattern.count]
    }
}
