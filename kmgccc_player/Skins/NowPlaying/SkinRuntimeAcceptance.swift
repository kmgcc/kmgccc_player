#if DEBUG
import AppKit
import Foundation

/// Opt-in acceptance of the real App hosts, with the same domain owners as user actions.
/// This is deliberately separate from unit tests and is absent from release builds.
@MainActor
enum SkinRuntimeAcceptance {
    private struct Sample: Codable {
        let step: String
        let windowSkin: String
        let fullscreenSkin: String
        let mode: String
        let audioConsumers: Int
        let meterSessions: Int
        let mainLyricsActive: Bool
        let fullscreenLyricsActive: Bool
        let mainLyricsMounted: Bool
        let fullscreenLyricsMounted: Bool
    }

    private struct Report: Codable {
        let completed: Bool
        let failures: [String]
        let samples: [Sample]
        let playbackPreserved: Bool
        let libraryPreserved: Bool
    }

    static func run(appSession: AppSessionHost) async {
        let outputArgument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--skin-acceptance-output=") }
        guard let output = outputArgument.map({ String($0.dropFirst("--skin-acceptance-output=".count)) }),
              output.hasPrefix("/"), let manager = appSession.skinManager,
              let playback = appSession.playbackCoordinator,
              let meter = appSession.ledMeterProvider,
              let window = AppKitMainSplitWindowController.show(appSession: appSession).window else {
            Log.error("[SkinAcceptance] Missing output path or live App dependencies", category: .ui)
            return
        }
        let settings = AppSettings.shared
        let fullscreen = FullscreenWindowManager.shared
        let savedWindowSkin = settings.selectedNowPlayingSkinID
        let savedFullscreen = settings.fullscreen.configuration
        let savedMode = appSession.uiState.contentMode
        let savedFrame = window.frame
        let savedSceneLyrics = appSession.uiState.skinSceneLyricsVisible
        let initialPlayback = playback.presentation
        let initialLibrary = appSession.activeLibraryBinding.activeSession
        var failures: [String] = []
        var samples: [Sample] = []
        var installedID: String?
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SkinAcceptance-\(UUID().uuidString)")
        defer {
            if let installedID { try? manager.removePackage(installedID, settings: settings) }
            settings.selectedNowPlayingSkinID = savedWindowSkin
            settings.fullscreen.setSkinID(savedFullscreen.skinID)
            settings.fullscreen.setVisualizerMode(savedFullscreen.visualizerMode)
            appSession.uiState.skinSceneLyricsVisible = savedSceneLyrics
            appSession.uiState.contentMode = savedMode
            window.setFrame(savedFrame, display: true)
            try? FileManager.default.removeItem(at: temporary)
        }

        func check(_ passed: Bool, _ message: String) {
            if !passed { failures.append(message) }
        }
        func sample(_ step: String) {
            let main = NativeLyricsSurfaceManager.shared.existingSurface(for: .main)
            let full = NativeLyricsSurfaceManager.shared.existingSurface(for: .fullscreen)
            samples.append(.init(
                step: step, windowSkin: settings.selectedNowPlayingSkinID,
                fullscreenSkin: settings.fullscreen.skinID, mode: String(describing: fullscreen.presentationMode),
                audioConsumers: AudioAnalysisHub.shared.skinDebugConsumerCount,
                meterSessions: meter.skinDebugSessionCount,
                mainLyricsActive: main?.isRenderingActive == true,
                fullscreenLyricsActive: full?.isRenderingActive == true,
                mainLyricsMounted: main?.view.superview != nil,
                fullscreenLyricsMounted: full?.view.superview != nil
            ))
            check(!(main?.isRenderingActive == true && full?.isRenderingActive == true), "\(step): two playback lyrics surfaces active")
        }

        await settle()
        appSession.uiState.showLibrary()
        await settle()
        sample("baseline.library")
        let baselineConsumers = AudioAnalysisHub.shared.skinDebugConsumerCount
        let baselineSessions = meter.skinDebugSessionCount

        // Mount the actual Now Playing page and each registered native definition.
        appSession.uiState.skinSceneLyricsVisible = true
        appSession.uiState.showNowPlaying()
        for skin in manager.catalog.skins(for: .window) {
            settings.selectedNowPlayingSkinID = skin.id
            await settle()
            sample("window.\(skin.id)")
            check(window.contentView?.bounds.isEmpty == false, "\(skin.id): empty main host")
        }
        for size in [NSSize(width: 1120, height: 850), NSSize(width: 820, height: 650)] {
            window.setContentSize(size)
            await settle()
            sample("window.resize.\(Int(size.width))x\(Int(size.height))")
        }

        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let id = "acceptance.\(UUID().uuidString.lowercased())"
            let archive = try makeArchive(id: id, name: "Runtime Acceptance", directory: temporary)
            installedID = try await manager.catalog.packages.importPackage(archive)
            try FileManager.default.removeItem(at: archive)
            settings.selectedNowPlayingSkinID = id
            settings.fullscreen.setSkinID(id)
            await settle()
            sample("package.selected.sourceZIPRemoved")
            check(NativeLyricsSurfaceManager.shared.existingSurface(for: .main)?.view.superview != nil,
                  "imported scene did not mount main lyrics")
            let revision = manager.catalog.revision(for: id)
            try manager.catalog.reload(id)
            await settle()
            check(manager.catalog.revision(for: id) > revision, "reload did not publish a new runtime revision")
            sample("package.reloaded.window")

            // Exercise actual embedded entry/exit, then the dedicated native fullscreen Space.
            for cycle in 0..<3 {
                window.makeKeyAndOrderFront(nil)
                fullscreen.showFullscreenPlayerInWindow()
                check(await waitUntil { fullscreen.presentationMode == .embeddedInWindow && !fullscreen.isTransitioning }, "embedded entry timed out")
                await settle()
                sample("embedded.\(cycle).entered")
                check(NativeLyricsSurfaceManager.shared.existingSurface(for: .fullscreen)?.view.superview != nil,
                      "embedded scene did not mount fullscreen lyrics")
                if cycle == 0 {
                    for skin in manager.catalog.skins(for: .fullscreen) {
                        settings.fullscreen.setSkinID(skin.id)
                        await settle()
                        sample("embedded.skin.\(skin.id)")
                    }
                    settings.fullscreen.setSkinID(id)
                    await settle()
                }
                try manager.catalog.reload(id)
                await settle()
                sample("embedded.\(cycle).reloaded")
                fullscreen.closeFullscreenPlayerInWindow()
                check(await waitUntil { fullscreen.presentationMode == .none && !fullscreen.isTransitioning }, "embedded exit timed out")
                await settle()
                sample("embedded.\(cycle).exited")
                appSession.uiState.showNowPlaying()
                await settle()
            }
            fullscreen.showFullscreenWindow()
            check(await waitUntil {
                fullscreen.presentationMode == .systemFullscreenSpace && !fullscreen.isTransitioning
                    && NSApp.windows.contains { $0.title == "kmgccc_player - Fullscreen" && $0.styleMask.contains(.fullScreen) }
            }, "native fullscreen entry timed out")
            await settle()
            sample("system.entered")
            check(NativeLyricsSurfaceManager.shared.existingSurface(for: .fullscreen)?.view.superview != nil,
                  "system scene did not mount fullscreen lyrics")
            try manager.catalog.reload(id)
            await settle()
            sample("system.reloaded")

            guard let package = manager.catalog.registeredSkin(for: id) as? PackagedSkin,
                  case .installed(let directory) = package.origin else { throw AcceptanceError.missingPackage }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let valid = try Data(contentsOf: manifestURL)
            let validRevision = manager.catalog.revision(for: id)
            try Data("{broken".utf8).write(to: manifestURL)
            do { try manager.catalog.reload(id); failures.append("invalid reload succeeded") } catch {}
            check(manager.catalog.revision(for: id) == validRevision, "failed reload changed live definition")
            try valid.write(to: manifestURL)
            sample("system.failedReloadPreserved")
            try manager.removePackage(id, settings: settings)
            installedID = nil
            await settle()
            sample("system.deletedToBuiltin")
            check(settings.selectedNowPlayingSkinID == SkinRegistry.defaultSkinID, "delete did not restore window default")
            check(settings.fullscreen.skinID == SkinRegistry.defaultFullscreenSkinID, "delete did not restore fullscreen default")
            fullscreen.closeFullscreenWindow()
            check(await waitUntil { fullscreen.presentationMode == .none && !fullscreen.isTransitioning }, "native fullscreen exit timed out")
            await settle()
            sample("system.exited")
        } catch { failures.append(error.localizedDescription) }

        // Drain host tasks and compare to the same library state, rather than to arbitrary zero.
        if fullscreen.presentationMode == .embeddedInWindow { fullscreen.closeFullscreenPlayerInWindow() }
        if fullscreen.presentationMode == .systemFullscreenSpace { fullscreen.closeFullscreenWindow() }
        _ = await waitUntil { fullscreen.presentationMode == .none && !fullscreen.isTransitioning }
        appSession.uiState.showLibrary()
        await settle(seconds: 3)
        sample("final.library")
        check(AudioAnalysisHub.shared.skinDebugConsumerCount <= baselineConsumers, "audio consumer count grew after host retirement")
        check(meter.skinDebugSessionCount <= baselineSessions, "meter lease count grew after host retirement")
        let finalPlayback = playback.presentation
        let playbackPreserved = initialPlayback.source == finalPlayback.source
            && initialPlayback.localTrack?.id == finalPlayback.localTrack?.id
            && initialPlayback.externalStableKey == finalPlayback.externalStableKey
            && initialPlayback.isPlaying == finalPlayback.isPlaying
            && (initialPlayback.isPlaying || abs(initialPlayback.currentTime - finalPlayback.currentTime) < 0.1)
        let libraryPreserved = initialLibrary === appSession.activeLibraryBinding.activeSession
        check(playbackPreserved, "skin operations changed playback")
        check(libraryPreserved, "skin operations replaced library session")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Report(completed: failures.isEmpty, failures: failures, samples: samples,
                                      playbackPreserved: playbackPreserved, libraryPreserved: libraryPreserved))
                .write(to: URL(fileURLWithPath: output), options: .atomic)
            Log.info("[SkinAcceptance] completed=\(failures.isEmpty) samples=\(samples.count) failures=\(failures.count)", category: .ui)
        } catch { Log.error("[SkinAcceptance] Could not save report: \(error.localizedDescription)", category: .ui) }
    }

    private static func settle(seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(12)
        while !condition() && Date() < deadline { await settle(seconds: 0.1) }
        return condition()
    }

    private enum AcceptanceError: Error { case missingPackage, archiveFailed }

    private static func makeArchive(id: String, name: String, directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = SkinSceneNode(id: "root", content: .column(children: [
            .component("lyrics", "native.lyrics", layout: .init(fillsWidth: true, fillsHeight: true)),
            .component("transport", "native.transport"),
        ], spacing: 12), layout: .init(padding: 24, fillsWidth: true, fillsHeight: true))
        let manifest = SkinPackageManifest(descriptor: .init(id: id, name: name, detail: "", systemImage: "paintpalette"), scene: .init(root: root))
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        let archive = directory.appendingPathComponent("skin.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AcceptanceError.archiveFailed }
        return archive
    }
}
#endif
