//
//  DockController.swift
//  myPlayer2
//
//  kmgccc_player - Dock tile progress and Dock menu playback controls
//

import AppKit

@MainActor
final class DockController: NSObject, NSMenuItemValidation {
    private struct DockPlaybackState: Equatable {
        var trackIdentity: String?
        var progress: Double?
        var progressColorSignature: String?
        var isPlaying: Bool
        var isControlEnabled: Bool
    }

    private weak var playbackCoordinator: PlaybackCoordinator?
    private let tileView = DockTileProgressView()
    private var refreshTimer: Timer?
    private var lastRenderedState = DockPlaybackState(
        trackIdentity: nil,
        progress: nil,
        progressColorSignature: nil,
        isPlaying: false,
        isControlEnabled: false
    )

    private let refreshInterval: TimeInterval = 0.5
    private let progressQuantization: Double = 1.0 / 512.0

    func installDockTile() {
        let dockTile = NSApp.dockTile
        let tileSize = dockTile.size
        let fallbackSize = NSSize(width: 128, height: 128)
        tileView.frame = NSRect(
            origin: .zero,
            size: tileSize.width > 0 && tileSize.height > 0 ? tileSize : fallbackSize
        )
        tileView.autoresizingMask = [.width, .height]
        tileView.iconImage = NSApp.applicationIconImage
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        tileView.progressColor = dockProgressColor()
        dockTile.contentView = tileView
        dockTile.display()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDockProgressVisibilityChanged),
            name: .dockProgressVisibilityChanged,
            object: nil
        )
    }

    func configure(playbackCoordinator: PlaybackCoordinator) {
        self.playbackCoordinator = playbackCoordinator
        refreshFromPlaybackCoordinator(forceDisplay: true)
        startRefreshTimer()
    }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        let state = currentPlaybackState()

        let playPauseTitle = state.isPlaying
            ? NSLocalizedString("menu.pause", comment: "Pause")
            : NSLocalizedString("menu.play", comment: "Play")

        let playPauseItem = NSMenuItem(
            title: playPauseTitle,
            action: #selector(togglePlayPause),
            keyEquivalent: ""
        )
        playPauseItem.target = self
        playPauseItem.isEnabled = state.isControlEnabled
        menu.addItem(playPauseItem)

        let previousItem = NSMenuItem(
            title: NSLocalizedString("menu.previous_track", comment: "Previous Track"),
            action: #selector(previousTrack),
            keyEquivalent: ""
        )
        previousItem.target = self
        previousItem.isEnabled = state.isControlEnabled
        menu.addItem(previousItem)

        let nextItem = NSMenuItem(
            title: NSLocalizedString("menu.next_track", comment: "Next Track"),
            action: #selector(nextTrack),
            keyEquivalent: ""
        )
        nextItem.target = self
        nextItem.isEnabled = state.isControlEnabled
        menu.addItem(nextItem)

        menu.addItem(.separator())

        let showWindowItem = NSMenuItem(
            title: NSLocalizedString("menu.show_main_window", comment: "Show Main Window"),
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showWindowItem.target = self
        showWindowItem.isEnabled = true
        menu.addItem(showWindowItem)

        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showMainWindow):
            return true
        case #selector(togglePlayPause), #selector(previousTrack), #selector(nextTrack):
            return currentPlaybackState().isControlEnabled
        default:
            return true
        }
    }

    @objc func togglePlayPause() {
        playbackCoordinator?.playPause()
        refreshFromPlaybackCoordinator(forceDisplay: true)
    }

    @objc func previousTrack() {
        playbackCoordinator?.previous()
        refreshFromPlaybackCoordinator(forceDisplay: true)
    }

    @objc func nextTrack() {
        playbackCoordinator?.next()
        refreshFromPlaybackCoordinator(forceDisplay: true)
    }

    @objc private func handleDockProgressVisibilityChanged() {
        refreshFromPlaybackCoordinator(forceDisplay: true)
    }

    @objc func showMainWindow() {
        revealMainWindow()
    }

    func applicationShouldHandleReopen(hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        return !revealMainWindow()
    }

    @discardableResult
    private func revealMainWindow() -> Bool {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if AppKitMainSplitWindowController.bringToFrontIfPossible() {
            return true
        }

        guard AppDelegate.launchMainWindowHandler != nil else { return false }
        AppDelegate.showMainWindow()
        return true
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFromPlaybackCoordinator(forceDisplay: false)
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshFromPlaybackCoordinator(forceDisplay: Bool) {
        playbackCoordinator?.refreshPresentation()
        let nextState = currentPlaybackState()
        guard forceDisplay || nextState != lastRenderedState else { return }

        lastRenderedState = nextState
        tileView.progress = nextState.progress
        tileView.progressColor = dockProgressColor()
        NSApp.dockTile.display()
    }

    private func currentPlaybackState() -> DockPlaybackState {
        guard let presentation = playbackCoordinator?.presentation else {
            return DockPlaybackState(
                trackIdentity: nil,
                progress: nil,
                progressColorSignature: nil,
                isPlaying: false,
                isControlEnabled: false
            )
        }

        let progress: Double?
        if AppSettings.shared.dockProgressVisible, presentation.hasTrack, presentation.duration > 0 {
            progress = quantizedProgress(presentation.progress)
        } else {
            progress = nil
        }

        return DockPlaybackState(
            trackIdentity: trackIdentity(for: presentation),
            progress: progress,
            progressColorSignature: progress == nil ? nil : colorSignature(for: dockProgressColor()),
            isPlaying: presentation.isPlaying,
            isControlEnabled: presentation.isControlEnabled
        )
    }

    private func quantizedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let clamped = min(max(progress, 0), 1)
        return (clamped / progressQuantization).rounded() * progressQuantization
    }

    private func trackIdentity(for presentation: NowPlayingPresentation) -> String? {
        if let localTrackID = presentation.localTrack?.id {
            return localTrackID.uuidString
        }
        if let stableKey = presentation.externalStableKey, !stableKey.isEmpty {
            return stableKey
        }
        guard presentation.hasTrack else { return nil }
        return [
            presentation.source.rawValue,
            presentation.title,
            presentation.artist,
            String(presentation.duration)
        ].joined(separator: "|")
    }

    private func dockProgressColor() -> NSColor {
        ThemeStore.shared.accentNSColor.usingColorSpace(.deviceRGB)
            ?? ThemeStore.shared.accentNSColor
    }

    private func colorSignature(for color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return color.description
        }
        return [
            rgb.redComponent,
            rgb.greenComponent,
            rgb.blueComponent,
            rgb.alphaComponent
        ]
        .map { String(format: "%.4f", Double($0)) }
        .joined(separator: ",")
    }
}

private final class DockTileProgressView: NSView {
    var iconImage: NSImage? {
        didSet { needsDisplay = true }
    }

    var progress: Double? {
        didSet { needsDisplay = true }
    }

    var progressColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !bounds.isEmpty else { return }

        NSColor.clear.setFill()
        bounds.fill()

        let image = iconImage ?? NSApp.applicationIconImage
        image?.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        if let progress {
            drawProgressBar(progress)
        }

        if let badgeLabel = NSApp.dockTile.badgeLabel, !badgeLabel.isEmpty {
            drawBadge(label: badgeLabel)
        }
    }

    private func drawProgressBar(_ progress: Double) {
        let clamped = min(max(progress, 0), 1)
        let horizontalInset = bounds.width * 0.13
        let barHeight = max(2.0, min(4.0, bounds.height * 0.028))
        let bottomInset = bounds.height * 0.075
        let trackRect = NSRect(
            x: bounds.minX + horizontalInset,
            y: bounds.minY + bottomInset,
            width: max(0, bounds.width - horizontalInset * 2),
            height: barHeight
        )
        guard trackRect.width > 0 else { return }

        let radius = barHeight / 2
        let shadowRect = trackRect.offsetBy(dx: 0, dy: -1)
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: shadowRect, xRadius: radius, yRadius: radius).fill()

        let themeColor = progressColor.usingColorSpace(.deviceRGB) ?? progressColor

        themeColor.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()

        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: max(barHeight, trackRect.width * CGFloat(clamped)),
            height: trackRect.height
        ).intersection(trackRect)

        themeColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }

    private func drawBadge(label: String) {
        let font = NSFont.boldSystemFont(ofSize: max(11, bounds.height * 0.14))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let badgeHeight = max(20, bounds.height * 0.22)
        let badgeWidth = max(badgeHeight, textSize.width + badgeHeight * 0.55)
        let badgeRect = NSRect(
            x: bounds.maxX - badgeWidth - bounds.width * 0.055,
            y: bounds.maxY - badgeHeight - bounds.height * 0.055,
            width: badgeWidth,
            height: badgeHeight
        )

        NSColor.systemRed.setFill()
        NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeHeight / 2,
            yRadius: badgeHeight / 2
        ).fill()

        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        label.draw(in: textRect, withAttributes: attributes)
    }
}
