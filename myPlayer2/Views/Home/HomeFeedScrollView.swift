//
//  HomeFeedScrollView.swift
//  myPlayer2
//
//  AppKit-backed scroll view for the Home feed.
//  Replaces the SwiftUI ScrollView { VStack } with an NSScrollView + NSStackView
//  of NSHostingView section hosts. Off-screen sections are swapped to stable-height
//  placeholders, stopping their SwiftUI body/layout evaluation entirely.
//
//  Virtualization strategy: stable-height placeholder swap, NOT isHidden.
//  - Visible section = real NSHostingView with SwiftUI content
//  - Off-screen section = lightweight NSView placeholder at cached measured height
//  - Swap happens on scroll via boundsDidChangeNotification
//
//  Gated by HomeDebugFlags.useAppKitFeed (default false until validated).
//

import AppKit
import SwiftUI

// MARK: - SwiftUI wrapper

struct HomeFeedScrollView: NSViewRepresentable {
    let heroModel: HomeHeroDisplayModel?
    let playlistsModel: HomePlaylistsDisplayModel
    let playlists: [Playlist]
    let artistsModel: HomeArtistsDisplayModel
    let artists: [ArtistEntry]
    let albumsModel: HomeAlbumsDisplayModel
    let albums: [AlbumEntry]
    let insightsModel: HomeInsightsDisplayModel
    let homeVM: HomeViewModel
    let mode: HomeLayoutMode
    let centerLeftPad: CGFloat
    let centerRightPad: CGFloat
    let onSwitchHeroTrack: (() -> Void)?

    func makeNSView(context: Context) -> HomeFeedNSScrollView {
        let scrollView = HomeFeedNSScrollView()
        scrollView.coordinator = context.coordinator
        scrollView.buildSectionHosts()
        return scrollView
    }

    func updateNSView(_ scrollView: HomeFeedNSScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.updateSections(parent: self)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject {
        var parent: HomeFeedScrollView

        init(_ parent: HomeFeedScrollView) {
            self.parent = parent
        }
    }
}

// MARK: - NSScrollView subclass

@MainActor
final class HomeFeedNSScrollView: NSScrollView {
    weak var coordinator: HomeFeedScrollView.Coordinator?

    private let feedDocumentView = HomeFeedDocumentView()

    /// Prefetch margin in points.
    private let prefetchMargin: CGFloat = 200

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        super.documentView = feedDocumentView
        contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        let offsetY = contentView.bounds.origin.y
        HomeAmbientMotionState.shared.setScrollOffset(offsetY)
        updateVisibility()
    }

    func buildSectionHosts() {
        feedDocumentView.buildSectionHosts()
    }

    func updateSections(parent: HomeFeedScrollView) {
        feedDocumentView.updateSections(parent: parent)
        updateVisibility()
    }

    private func updateVisibility() {
        feedDocumentView.updateVisibility(
            visibleRect: contentView.bounds,
            prefetchMargin: prefetchMargin
        )
    }
}

// MARK: - Document view (NSStackView)

@MainActor
final class HomeFeedDocumentView: NSStackView {
    private var sectionHosts: [HomeFeedSectionHost] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        edgeInsets = NSEdgeInsets(
            top: HomeFeedSection.topInset,
            left: 0,
            bottom: HomeFeedSection.bottomInset,
            right: 0
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func buildSectionHosts() {
        for host in sectionHosts {
            removeArrangedSubview(host)
            host.removeFromSuperview()
        }
        sectionHosts.removeAll()

        let sections: [HomeFeedSection] = [.hero, .playlists, .artists, .albums, .insights, .footer, .tailSpacer]
        for section in sections {
            let host = HomeFeedSectionHost(section: section)
            addArrangedSubview(host)
            sectionHosts.append(host)
        }
    }

    func updateSections(parent: HomeFeedScrollView) {
        let spacing = HomeFeedSection.sectionSpacing(for: parent.mode)
        self.spacing = spacing

        for host in sectionHosts {
            switch host.section {
            case .hero:
                if !HomeDebugFlags.disableHero, let heroModel = parent.heroModel {
                    host.showContent(
                        AnyView(
                            HomeHeroView(
                                model: heroModel,
                                onSwitchTrack: parent.onSwitchHeroTrack
                            )
                            .padding(.leading, parent.centerLeftPad)
                            .padding(.trailing, parent.centerRightPad)
                        )
                    )
                } else {
                    host.showPlaceholder()
                }

            case .playlists:
                if !HomeDebugFlags.disablePlaylists, !parent.playlists.isEmpty {
                    host.showContent(
                        AnyView(
                            EquatableView(content: HomePlaylistsSection(
                                model: parent.playlistsModel,
                                playlists: parent.playlists
                            ))
                            .padding(.leading, parent.centerLeftPad)
                            .padding(.trailing, parent.centerRightPad)
                        )
                    )
                } else {
                    host.showPlaceholder()
                }

            case .artists:
                if !HomeDebugFlags.disableArtists, !parent.artists.isEmpty {
                    host.showContent(
                        AnyView(
                            EquatableView(content: HomeArtistsSection(
                                model: parent.artistsModel,
                                artists: parent.artists
                            ))
                        )
                    )
                } else {
                    host.showPlaceholder()
                }

            case .albums:
                if !HomeDebugFlags.disableAlbums, !parent.albums.isEmpty {
                    host.showContent(
                        AnyView(
                            EquatableView(content: HomeAlbumsSection(
                                model: parent.albumsModel,
                                albums: parent.albums
                            ))
                        )
                    )
                } else {
                    host.showPlaceholder()
                }

            case .insights:
                if !HomeDebugFlags.disableInsights {
                    host.showContent(
                        AnyView(
                            EquatableView(content: HomeInsightsSection(
                                model: parent.insightsModel,
                                homeVM: parent.homeVM
                            ))
                        )
                    )
                } else {
                    host.showPlaceholder()
                }

            case .footer:
                host.showContent(
                    AnyView(
                        HomeFooterView()
                            .padding(.leading, parent.centerLeftPad)
                            .padding(.trailing, parent.centerRightPad)
                    )
                )

            case .tailSpacer:
                host.showContent(
                    AnyView(
                        Color.clear.frame(height: HomeFeedSection.tailSpacerHeight)
                    )
                )
            }
        }
    }

    func updateVisibility(visibleRect: NSRect, prefetchMargin: CGFloat) {
        let extendedRect = visibleRect.insetBy(dx: 0, dy: -prefetchMargin)

        for host in sectionHosts {
            let hostFrame = host.frame
            let isVisible = hostFrame.intersects(extendedRect)

            if isVisible {
                host.ensureContentVisible()
            } else {
                host.swapToPlaceholder()
            }
        }
    }
}

// MARK: - Section host

@MainActor
final class HomeFeedSectionHost: NSView {
    let section: HomeFeedSection

    /// The real SwiftUI hosting view (when visible).
    private var hostingView: NSHostingView<AnyView>?

    /// Lightweight placeholder (when off-screen).
    private var placeholderView: NSView?

    /// Cached intrinsic height from the last time the content was measured.
    private var cachedHeight: CGFloat = 100

    /// Last content shown — used to restore when scrolling back into view.
    private var lastContent: AnyView?

    /// Whether we're currently showing real content.
    private var isShowingContent = false

    init(section: HomeFeedSection) {
        self.section = section
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func showContent(_ content: AnyView) {
        lastContent = content

        // Remove placeholder if present
        if let placeholder = placeholderView {
            placeholder.removeFromSuperview()
            placeholderView = nil
        }

        if let existing = hostingView {
            existing.rootView = content
        } else {
            let hosting = NSHostingView(rootView: content)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.sizingOptions = .minSize
            addSubview(hosting)
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            hosting.topAnchor.constraint(equalTo: topAnchor).isActive = true
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            hostingView = hosting
        }
        isShowingContent = true
    }

    func showPlaceholder() {
        if hostingView == nil && placeholderView == nil {
            let placeholder = NSView()
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            placeholder.wantsLayer = true
            addSubview(placeholder)
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            placeholder.topAnchor.constraint(equalTo: topAnchor).isActive = true
            placeholder.heightAnchor.constraint(equalToConstant: cachedHeight).isActive = true
            placeholderView = placeholder
            isShowingContent = false
        }
    }

    func ensureContentVisible() {
        guard !isShowingContent, let content = lastContent else { return }
        showContent(content)
    }

    func swapToPlaceholder() {
        guard isShowingContent, let hosting = hostingView else { return }

        cachedHeight = hosting.fittingSize.height
        hosting.removeFromSuperview()

        let placeholder = NSView()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.wantsLayer = true
        addSubview(placeholder)
        placeholder.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        placeholder.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        placeholder.topAnchor.constraint(equalTo: topAnchor).isActive = true
        placeholder.heightAnchor.constraint(equalToConstant: cachedHeight).isActive = true
        placeholderView = placeholder

        hostingView = nil
        isShowingContent = false
    }
}

// MARK: - Footer view (extracted from HomeView)

private struct HomeFooterView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("\u{201C}Where words fail, music speaks.\u{201D}")
                .font(.system(size: 20, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("\u{8A00}\u{6240}\u{4E0D}\u{53CA}\u{5904}\u{FF0C}\u{7B19}\u{7BAB}\u{76F8}\u{7EE7}\u{3002}")
                .font(.system(.callout, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("— Hans Christian Andersen")
                .font(.system(.caption2, weight: .ultraLight))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.quaternary)
                .padding(.top, 4)
        }
        .padding(.top, 36)
        .padding(.bottom, 24)
    }
}
