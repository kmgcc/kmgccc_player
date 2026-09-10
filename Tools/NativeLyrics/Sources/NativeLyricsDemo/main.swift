import AppKit
import AVFoundation
import NativeLyrics
import QuartzCore
import OSLog

@MainActor final class DemoController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum Sample: Int, CaseIterable {
        case library, motion, glow, duetRuby, chorus
        var title: String {
            switch self {
            case .library: return "Library song"
            case .motion: return "Motion laboratory"
            case .glow: return "Glow showcase"
            case .duetRuby: return "Duet + Ruby"
            case .chorus: return "Chorus / background"
            }
        }
        var resourceName: String {
            switch self {
            case .library: return "song.ttml"
            case .motion: return "complex.ttml"
            case .glow: return "glow-showcase.ttml"
            case .duetRuby: return "duet-ruby.ttml"
            case .chorus: return "chorus-background.ttml"
            }
        }
        var usesAudio: Bool { self == .library }
    }

    private var window: NSWindow!
    private let lyrics = LyricsView(frame:.zero)
    private let play = NSButton(title:"Play",target:nil,action:nil)
    private let slider = NSSlider(value:0,minValue:0,maxValue:70,target:nil,action:nil)
    private let status = NSTextField(labelWithString:""), clockLabel = NSTextField(labelWithString:"0:00.0 / 1:10.0")
    private let titleLabel = NSTextField(labelWithString:"Native Lyrics")
    private var player: AVAudioPlayer?
    private var clock = LyricsClock()
    private var timer: Timer?
    private var frameCosts: [Double] = [], frameIntervals: [Double] = []
    private var lastFrameHost: Double?, measurementStart: Double?
    private var performanceOutput: String?
    private var measurementDuration = 12.0
    private var duration = 70.0
    private var mediaURL: URL?
    private let samplePopup = NSPopUpButton()
    private let libraryPopup = NSPopUpButton()
    private var librarySongs: [DemoLibrarySong] = []
    private var catalogTask: Task<Void, Never>?
    private var selectedSample: Sample = .motion
    private let logger = Logger(subsystem:"dev.kmgccc.NativeLyricsDemo",category:"demo")
    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:790,height:830),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Native Lyrics Demo"; window.minSize = NSSize(width:380,height:420); window.delegate = self
        window.backgroundColor = NSColor(srgbRed:0.055,green:0.075,blue:0.12,alpha:1)
        window.appearance = NSAppearance(named:.darkAqua)
        let root = NSView(); window.contentView = root
        let controls = NSStackView(); controls.orientation = .vertical; controls.spacing = 9; controls.alignment = .leading
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
        play.target = self; play.action = #selector(toggle)
        row.addArrangedSubview(play)
        for (title,action) in [("−5s",#selector(back)),("+5s",#selector(forward)),("Follow",#selector(follow)),("Open TTML…",#selector(openTTML)),("Audio…",#selector(openAudio))] {
            row.addArrangedSubview(NSButton(title:title,target:self,action:action))
        }
        let profile = NSPopUpButton(); profile.addItems(withTitles:["Current player","Official upstream"]); profile.target = self; profile.action = #selector(changeProfile(_:)); row.addArrangedSubview(profile)
        controls.addArrangedSubview(row)
        let timing = NSStackView(views:[clockLabel,slider]); timing.orientation = .horizontal
        slider.target = self; slider.action = #selector(scrub); slider.isContinuous = true; controls.addArrangedSubview(timing)
        let options = NSStackView(); options.orientation = .horizontal; options.spacing = 10
        for (i,name) in ["Emphasis","Glow","Translation","Ruby","Blur"].enumerated() {
            let button = NSButton(checkboxWithTitle:name,target:self,action:#selector(option(_:))); button.tag = i; button.state = .on; options.addArrangedSubview(button)
        }
        let font = NSSlider(value:38,minValue:20,maxValue:70,target:self,action:#selector(fontSize(_:))); font.toolTip = "Font size"; options.addArrangedSubview(font)
        controls.addArrangedSubview(options)
        let glowRow = NSStackView(); glowRow.orientation = .horizontal; glowRow.spacing = 8
        glowRow.addArrangedSubview(NSTextField(labelWithString:"Glow radius"))
        let glowSlider = NSSlider(value:1,minValue:0.5,maxValue:3,target:self,action:#selector(glowRadius(_:))); glowSlider.toolTip = "AMLL glow radius scale"; glowSlider.widthAnchor.constraint(equalToConstant:190).isActive = true; glowRow.addArrangedSubview(glowSlider)
        glowRow.addArrangedSubview(NSTextField(labelWithString:"0.5×  —  3×"))
        controls.addArrangedSubview(glowRow); controls.addArrangedSubview(status)
        let interludeRow = NSStackView(); interludeRow.orientation = .horizontal; interludeRow.spacing = 8
        interludeRow.addArrangedSubview(NSTextField(labelWithString:"Interlude dots"))
        let interludeSlider = NSSlider(value:1,minValue:0.5,maxValue:2.5,target:self,action:#selector(interludeDotScale(_:)))
        interludeSlider.toolTip = "Interlude dot size"; interludeSlider.widthAnchor.constraint(equalToConstant:190).isActive = true
        interludeRow.addArrangedSubview(interludeSlider); interludeRow.addArrangedSubview(NSTextField(labelWithString:"0.5×  —  2.5×"))
        controls.addArrangedSubview(interludeRow)
        let styles = NSStackView(); styles.orientation = .horizontal; styles.spacing = 10
        let style = NSPopUpButton(); style.addItems(withTitles:LyricsSurfaceStyle.allCases.map(\.rawValue)); style.target = self; style.action = #selector(changeSurface(_:)); styles.addArrangedSubview(style)
        let mode = NSPopUpButton(); mode.addItems(withTitles:["Smooth words","Discrete words","Line timing only"]); mode.target = self; mode.action = #selector(changeMode(_:)); styles.addArrangedSubview(mode)
        controls.insertArrangedSubview(styles,at:3)
        let samples = NSStackView(); samples.orientation = .horizontal; samples.spacing = 8
        samples.addArrangedSubview(NSTextField(labelWithString:"Sample"))
        samplePopup.addItems(withTitles:Sample.allCases.map(\.title)); samplePopup.target = self; samplePopup.action = #selector(changeSample(_:)); samples.addArrangedSubview(samplePopup)
        controls.insertArrangedSubview(samples,at:3)
        let library = NSStackView(); library.orientation = .horizontal; library.spacing = 8
        library.addArrangedSubview(NSTextField(labelWithString:"Library songs"))
        libraryPopup.addItem(withTitle:"Scanning player library…"); libraryPopup.isEnabled = false; libraryPopup.target = self; libraryPopup.action = #selector(changeLibrarySong(_:)); library.addArrangedSubview(libraryPopup)
        controls.insertArrangedSubview(library,at:4)
        let blends = NSStackView(); blends.orientation = .horizontal; blends.spacing = 8
        for (tag,title) in ["Inactive", "Current", "Highlight"].enumerated() {
            blends.addArrangedSubview(NSTextField(labelWithString:title))
            let popup = NSPopUpButton(); popup.tag = tag
            popup.addItems(withTitles:["normal","plusLighter","plusDarker"])
            popup.target = self; popup.action = #selector(changeChannelBlend(_:))
            blends.addArrangedSubview(popup)
        }
        lyrics.configuration.channelBlend = .init(inactive:.normal,current:.normal,highlight:.normal)
        controls.addArrangedSubview(blends)
        let blendTest = NSButton(checkboxWithTitle:"Colored blend test",target:self,action:#selector(toggleBlendTest(_:)))
        controls.addArrangedSubview(blendTest)
        lyrics.configuration.backdropColor = LyricsColor(0.055,0.075,0.12)

        for view in [titleLabel,lyrics,controls] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        titleLabel.font = .systemFont(ofSize:14,weight:.semibold); titleLabel.lineBreakMode = .byTruncatingTail
        status.font = .monospacedSystemFont(ofSize:10,weight:.regular); status.textColor = .secondaryLabelColor
        clockLabel.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo:root.topAnchor,constant:12),titleLabel.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),titleLabel.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),
            lyrics.topAnchor.constraint(equalTo:titleLabel.bottomAnchor,constant:5),lyrics.leadingAnchor.constraint(equalTo:root.leadingAnchor),lyrics.trailingAnchor.constraint(equalTo:root.trailingAnchor),lyrics.bottomAnchor.constraint(equalTo:controls.topAnchor,constant:-10),
            controls.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:18),controls.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-18),controls.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-18),
            timing.widthAnchor.constraint(equalTo:controls.widthAnchor),slider.widthAnchor.constraint(greaterThanOrEqualToConstant:120)
        ])
        lyrics.onSeek = { [weak self] in self?.seek($0,motion:.cascade,playAfter:true) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let args = CommandLine.arguments
        let supplied = args.firstIndex(of:"--ttml").flatMap { $0+1<args.count ? URL(fileURLWithPath:args[$0+1]) : nil }
        if let supplied {
            samplePopup.selectItem(at:-1); load(supplied)
        } else {
            let local = Bundle.main.resourceURL?.appendingPathComponent("song.ttml")
            if let local, FileManager.default.fileExists(atPath:local.path), bundledLibrarySong() != nil {
                selectedSample = .library; samplePopup.selectItem(at:Sample.library.rawValue); loadFixture(.library)
            } else {
                // Motion starts with a five-second lead-in. Keep the first
                // launch visibly populated on machines without the optional
                // local library fixture; Motion remains selectable below.
                selectedSample = .glow; samplePopup.selectItem(at:Sample.glow.rawValue); loadFixture(.glow)
            }
        }
        func argument(_ name: String) -> String? { args.firstIndex(of:name).flatMap { $0+1<args.count ? args[$0+1] : nil } }
        performanceOutput = argument("--performance-output")
        measurementDuration = argument("--measure-seconds").flatMap(Double.init) ?? 12
        if let start = argument("--start").flatMap(Double.init) { seek(start) }
        lyrics.onFrame = { [weak self] frame in self?.recordFrame(frame) }
        if args.contains("--autoplay") { toggle() }
        refreshLibraryCatalog()
        timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.updateControls() } }
        RunLoop.main.add(timer!,forMode:.common)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); catalogTask?.cancel(); lyrics.releaseRenderingResources(); player?.stop() }
    private func makeMenu() {
        let menu = NSMenu(), app = NSMenuItem(); menu.addItem(app); let submenu = NSMenu(); app.submenu = submenu
        submenu.addItem(withTitle:"Quit Native Lyrics Demo",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let transport = NSMenuItem(); menu.addItem(transport); let actions = NSMenu(title:"Playback"); transport.submenu = actions
        let p = actions.addItem(withTitle:"Play / Pause",action:#selector(toggle),keyEquivalent:" "); p.target = self; p.keyEquivalentModifierMask = []
        let f = actions.addItem(withTitle:"Follow current lyrics",action:#selector(follow),keyEquivalent:"f"); f.target = self
        NSApp.mainMenu = menu
    }
    private func load(_ url: URL, displayTitle: String? = nil) {
        do {
            let data = try Data(contentsOf:url)
            let imported = try DemoTTMLImporter.load(data)
            // A number of valid library exports contain an instrumental lead-in
            // before the first timed word. Starting the paused Demo at media
            // zero would make every visible row a blurred future row. Preview
            // the first timed word when no explicit start was requested;
            // the slider still allows returning to zero for timing checks.
            try lyrics.load(ttml:imported.data,time:0,playing:false)
            let firstLine = lyrics.diagnosticTimings.first?.main
            let firstWord = firstLine?.words.first { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            let firstWordStart = firstWord?.range.start ?? firstLine?.range.start ?? 0
            // Advance a small, bounded fraction into the first word so the
            // initial paused frame is visibly readable rather than sitting on
            // the mask's all-inactive leading edge.
            let previewNudge = firstWord.map { min(0.15,max(0.06,$0.range.duration*0.5)) } ?? 0
            let previewTime = max(0,firstWordStart+previewNudge)
            frameCosts.removeAll(); frameIntervals.removeAll(); lastFrameHost = nil; measurementStart = nil
            mediaURL = url; duration = max(1,lyrics.document?.duration ?? 70); slider.maxValue = duration
            player?.stop(); player = nil; clock.synchronize(time:previewTime,playing:false,host:CACurrentMediaTime())
            if previewTime > 0.001 { lyrics.synchronize(time:previewTime,playing:false,seek:true) }
            let sidecar = sidecarTitle(for: url)
            let documentTitle = imported.document.title == "TTML Lyrics" ? nil : imported.document.title
            let title = displayTitle ?? sidecar ?? documentTitle ?? DemoTTMLImporter.metadataTitle(data) ?? url.deletingPathExtension().lastPathComponent
            titleLabel.stringValue = title
            updateControls()
        } catch { showError(error, url:url) }
    }
    private func loadFixture(_ fixture: Sample) {
        selectedSample = fixture
        libraryPopup.selectItem(at:-1)
        player?.stop(); player = nil
        let url = Bundle.main.resourceURL!.appendingPathComponent(fixture.resourceName)
        load(url)
        if fixture.usesAudio, let audio = Bundle.main.resourceURL?.appendingPathComponent("audio.m4a"), FileManager.default.fileExists(atPath:audio.path) {
            attachAudio(audio)
        }
    }
    private func attachAudio(_ url: URL) {
        let wasPlaying = clock.isPlaying
        let current = max(0,clock.time(at:CACurrentMediaTime()))
        player?.stop()
        do {
            let next = try AVAudioPlayer(contentsOf:url)
            next.prepareToPlay(); next.currentTime = min(current,next.duration); player = next
            duration = max(duration,next.duration); slider.maxValue = duration
            seek(min(current,next.duration),playAfter:wasPlaying)
        }
        catch { showError(error, url:url) }
    }
    private var time: Double { player?.currentTime ?? clock.time(at:CACurrentMediaTime()) }
    @objc private func toggle() {
        if !clock.isPlaying { lyrics.layoutSubtreeIfNeeded(); lyrics.render(at:CACurrentMediaTime()) }
        let now = CACurrentMediaTime(), current = time, playing = !clock.isPlaying
        clock.synchronize(time:current,playing:playing,host:now)
        if playing { player?.play() } else { player?.pause() }
        lyrics.synchronize(time:current,playing:playing,hostTime:now); updateControls()
    }
    private func seek(_ time: Double, motion: LyricsSeekMotion = .immediate, playAfter: Bool = false) {
        let value = max(0,min(duration,time)), now = CACurrentMediaTime()
        player?.currentTime = value; clock.synchronize(time:value,playing:playAfter || clock.isPlaying,host:now)
        if playAfter { player?.play() }
        lyrics.synchronize(time:value,playing:clock.isPlaying,seek:true,motion:motion,hostTime:now); updateControls()
    }
    @objc private func scrub() { seek(slider.doubleValue) }
    @objc private func changeChannelBlend(_ sender: NSPopUpButton) {
        let mode: LyricsBlendMode = [.normal,.plusLighter,.plusDarker][sender.indexOfSelectedItem]
        switch sender.tag {
        case 0: lyrics.configuration.channelBlend.inactive = mode
        case 1: lyrics.configuration.channelBlend.current = mode
        default: lyrics.configuration.channelBlend.highlight = mode
        }
    }
    @objc private func back() { seek(time-5) }
    @objc private func forward() { seek(time+5) }
    @objc private func follow() { lyrics.followCurrentLyrics() }
    @objc private func changeSample(_ sender: NSPopUpButton) {
        guard let fixture = Sample(rawValue:sender.indexOfSelectedItem) else { return }
        loadFixture(fixture)
    }
    @objc private func changeLibrarySong(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard librarySongs.indices.contains(index) else { return }
        let song = librarySongs[index]
        samplePopup.selectItem(at:-1)
        player?.stop(); player = nil
        load(song.lyricURL, displayTitle: song.title)
        if let audioURL = song.audioURL { attachAudio(audioURL) }
    }
    @objc private func changeProfile(_ sender: NSPopUpButton) { lyrics.configuration.profile = sender.indexOfSelectedItem == 0 ? .currentPlayer : .upstream }
    @objc private func changeSurface(_ sender: NSPopUpButton) {
        lyrics.configuration.surface = LyricsSurfaceStyle.allCases[sender.indexOfSelectedItem]
        lyrics.configuration.fullscreenAppleStyleMode = lyrics.configuration.surface == .appleStyle
        if lyrics.configuration.surface == .coverBlurDark { lyrics.configuration.coverBlurProfile = .darker }
        if lyrics.configuration.surface == .coverBlurLight { lyrics.configuration.coverBlurProfile = .lighter }
        var palette = LyricsPalette()
        if lyrics.configuration.surface == .coverBlurDark {
            palette.mainActive = .black; palette.mainInactive = LyricsColor(0.55,0.53,0.51); palette.translation = LyricsColor(0.5,0.48,0.46)
            palette.backgroundInactive = LyricsColor(0.5,0.48,0.46); palette.backgroundKaraoke = LyricsColor(0.10,0.09,0.08); palette.emphasisGlow = .black
            palette.backgroundBaseOpacity = 0.44; palette.backgroundKaraokeOpacity = 0.86
            window.backgroundColor = NSColor(srgbRed:0.87,green:0.84,blue:0.80,alpha:1)
        } else { window.backgroundColor = NSColor(srgbRed:0.055,green:0.075,blue:0.12,alpha:1) }
        lyrics.configuration.palette = palette
        let bg = window.backgroundColor.usingColorSpace(.sRGB)!
        lyrics.configuration.backdropColor = LyricsColor(bg.redComponent,bg.greenComponent,bg.blueComponent)
    }
    @objc private func toggleBlendTest(_ sender: NSButton) {
        let enabled = sender.state == .on
        lyrics.configuration.backdropColor = enabled ? LyricsColor(0.36,0.2,0.3) : LyricsColor(0.055,0.075,0.12)
        lyrics.configuration.palette.mainActive = enabled ? LyricsColor(0.25,0.7,0.6) : .white
    }
    @objc private func changeMode(_ sender: NSPopUpButton) { lyrics.configuration.lineTimingOnly = sender.indexOfSelectedItem == 2; lyrics.configuration.highlightMode = sender.indexOfSelectedItem == 1 ? .discrete : .smooth }
    @objc private func fontSize(_ sender: NSSlider) { lyrics.configuration.fontSize = sender.doubleValue }
    @objc private func glowRadius(_ sender: NSSlider) { lyrics.configuration.glowRadiusScale = sender.doubleValue }
    @objc private func interludeDotScale(_ sender: NSSlider) { lyrics.configuration.interludeDotScale = sender.doubleValue }
    @objc private func option(_ sender: NSButton) {
        let enabled = sender.state == .on
        switch sender.tag { case 0: lyrics.configuration.emphasis = enabled; case 1: lyrics.configuration.glow = enabled; case 2: lyrics.configuration.showTranslation = enabled; case 3: lyrics.configuration.showRuby = enabled; default: lyrics.configuration.blur = enabled }
    }
    @objc private func openTTML() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.message = "Choose a standard TTML file or an AMLL player-library lyrics.ttml"; panel.beginSheetModal(for:window) { [weak self] response in if response == .OK, let url = panel.url { self?.samplePopup.selectItem(at:-1); self?.libraryPopup.selectItem(at:-1); self?.load(url) } } }
    @objc private func openAudio() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.beginSheetModal(for:window) { [weak self] response in if response == .OK, let url = panel.url { self?.attachAudio(url) } } }
    private func refreshLibraryCatalog() {
        let bundled = bundledLibrarySong()
        librarySongs = bundled.map { [$0] } ?? []
        rebuildLibraryPopup()
        libraryPopup.toolTip = "Scanning registered player-library Tracks folders…"
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .utility) { DemoLibraryCatalog.discover() }.value
            // Keep the completed result even if the short-lived refresh task
            // was marked cancelled while the XML files were being inspected;
            // windowWillClose still releases the UI and no second refresh can
            // race this one during the Demo lifetime.
            guard let self else { return }
            var merged = bundled.map { [$0] } ?? []
            let known = Set(merged.map { $0.lyricURL.standardizedFileURL })
            merged.append(contentsOf: discovered.filter { !known.contains($0.lyricURL.standardizedFileURL) })
            self.librarySongs = merged
            self.rebuildLibraryPopup()
            self.libraryPopup.toolTip = "\(merged.count) selectable player-library songs"
            self.logger.info("Loaded \(merged.count) selectable library songs")
        }
    }
    private func bundledLibrarySong() -> DemoLibrarySong? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("song.ttml"),
              FileManager.default.fileExists(atPath:url.path),
              let data = try? Data(contentsOf:url),
              let imported = try? DemoTTMLImporter.load(data) else { return nil }
        let audio = Bundle.main.resourceURL?.appendingPathComponent("audio.m4a")
        return DemoLibrarySong(title: imported.document.title, subtitle: "Bundled word-timed fixture", lyricURL: url, audioURL: audio, rootLabel: "Demo")
    }
    private func sidecarTitle(for url: URL) -> String? {
        let metadataURL = url.deletingLastPathComponent().appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["title"] as? String else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
    private func rebuildLibraryPopup() {
        libraryPopup.removeAllItems()
        guard !librarySongs.isEmpty else {
            libraryPopup.addItem(withTitle:"No TTML lyrics found — use Open TTML…")
            libraryPopup.isEnabled = false
            return
        }
        for song in librarySongs {
            let label = song.subtitle.isEmpty ? song.title : "\(song.title) — \(song.subtitle)"
            libraryPopup.addItem(withTitle:label)
        }
        libraryPopup.isEnabled = true
        if let current = mediaURL, let index = librarySongs.firstIndex(where: { $0.lyricURL.standardizedFileURL == current.standardizedFileURL }) {
            libraryPopup.selectItem(at:index)
        }
    }
    private func recordFrame(_ frame: LyricsFrame) {
        guard clock.isPlaying else { lastFrameHost = nil; return }
        let now = CACurrentMediaTime()
        if measurementStart == nil { measurementStart = now }
        if frame.renderMilliseconds.isFinite { frameCosts.append(frame.renderMilliseconds) }
        if let lastFrameHost {
            let interval = (now-lastFrameHost)*1000
            if interval.isFinite && interval >= 0 { frameIntervals.append(interval) }
        }
        lastFrameHost = now
        if frameCosts.count > 7200 { frameCosts.removeFirst(120); frameIntervals.removeFirst(min(120,frameIntervals.count)) }
        if let path = performanceOutput, now-(measurementStart ?? now) >= measurementDuration {
            performanceOutput = nil
            let callbackMean = frameIntervals.isEmpty ? 0 : frameIntervals.reduce(0,+)/Double(frameIntervals.count)
            let callbackHz = callbackMean > 0 && callbackMean.isFinite ? 1000/callbackMean : 0
            let jsonNumber: (Double) -> Double = { $0.isFinite ? $0 : 0 }
            let report: [String:Any] = ["renderMedianMS":percentile(frameCosts,0.5),"renderP95MS":percentile(frameCosts,0.95),"renderMaxMS":frameCosts.max() ?? 0,
                "callbackIntervalP95MS":percentile(frameIntervals,0.95),"callbackHz":callbackHz,
                "screenMaxHz":window.screen?.maximumFramesPerSecond ?? 0,"frames":frameCosts.count,"duration":jsonNumber(now-(measurementStart ?? now)),"cacheBytes":frame.glyphCacheBytes,
                "width":jsonNumber(lyrics.bounds.width),"height":jsonNumber(lyrics.bounds.height),"renderCostsMS":frameCosts.map(jsonNumber),"callbackIntervalsMS":frameIntervals.map(jsonNumber)]
            do {
                let outputURL = URL(fileURLWithPath:path)
                try FileManager.default.createDirectory(at:outputURL.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:outputURL,options:.atomic)
            }
            catch { logger.error("Performance report failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }; let sorted = values.sorted()
        return sorted[min(sorted.count-1,Int(Double(sorted.count-1)*fraction))]
    }
    private func updateControls() {
        var current = time
        if current >= duration && clock.isPlaying { current = duration; player?.pause(); clock.synchronize(time:current,playing:false,host:CACurrentMediaTime()) }
        if player != nil && clock.isPlaying { lyrics.synchronize(time:current,playing:true) }
        slider.doubleValue = current; play.title = clock.isPlaying ? "Pause" : "Play"
        func format(_ t: Double) -> String {
            let seconds = t.truncatingRemainder(dividingBy:60)
            return String(format:"%d:%04.1f",Int(t)/60,seconds)
        }
        clockLabel.stringValue = "\(format(current)) / \(format(duration))"
        if let frame = lyrics.lastFrame {
            let intervals = Array(frameIntervals.suffix(240)), costs = Array(frameCosts.suffix(240))
            let hz = intervals.isEmpty ? 0 : 1000/(intervals.reduce(0,+)/Double(intervals.count))
            status.stringValue = String(format:"%@ · %.0f Hz callbacks · render p95 %.2f ms · %.1f MB glyph cache",frame.following ? "Following" : "Manual scroll",hz,percentile(costs,0.95),Double(frame.glyphCacheBytes)/1048576)

        }
    }
    private func showError(_ error: Error, url: URL? = nil) {
        logger.error("\(error.localizedDescription,privacy:.public)")
        let alert = NSAlert(); alert.messageText = "Unable to load lyrics"
        let location = url.map { "\n\nFile: \($0.path)" } ?? ""
        alert.informativeText = "\(error.localizedDescription)\(location)\n\nThe native engine accepts AMLL TTML directly. LRC and other lyric formats remain outside this Demo import path."
        alert.alertStyle = .warning; alert.addButton(withTitle:"OK"); alert.beginSheetModal(for:window)
    }
}

MainActor.assumeIsolated {
    if let index = CommandLine.arguments.firstIndex(of: "--dump-import"), index + 1 < CommandLine.arguments.count {
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        do {
            let imported = try DemoTTMLImporter.load(Data(contentsOf: url))
            print("title=\(imported.document.title) duration=\(imported.document.duration) groups=\(imported.document.groups.count) timing=\(imported.document.timingMode.rawValue)")
            for group in imported.document.groups.prefix(8) {
                let words = group.main.words.map { $0.text.replacingOccurrences(of: " ", with: "·") }.joined(separator: "|")
                print("\(group.main.range.start)-\(group.main.range.end) \(words)")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    if CommandLine.arguments.contains("--dump-catalog") {
        let songs = DemoLibraryCatalog.discover()
        print("songs=\(songs.count)")
        for song in songs.prefix(12) { print("\(song.title)\t\(song.subtitle)\t\(song.lyricURL.path)") }
        exit(0)
    }
    let application = NSApplication.shared
    let delegate = DemoController()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
