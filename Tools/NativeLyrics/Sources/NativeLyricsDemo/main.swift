import AppKit
import AVFoundation
import NativeLyrics
import QuartzCore
import OSLog

@MainActor final class DemoController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let lyrics = LyricsView(frame:.zero)
    private let play = NSButton(title:"Play",target:nil,action:nil)
    private let slider = NSSlider(value:0,minValue:0,maxValue:70,target:nil,action:nil)
    private let status = NSTextField(labelWithString:""), clockLabel = NSTextField(labelWithString:"0:00 / 1:10")
    private let titleLabel = NSTextField(labelWithString:"Native Lyrics")
    private var player: AVAudioPlayer?
    private var clock = LyricsClock()
    private var timer: Timer?
    private var duration = 70.0
    private var mediaURL: URL?
    private var genericCoverButton: NSButton?
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
        controls.addArrangedSubview(options); controls.addArrangedSubview(status)
        let styles = NSStackView(); styles.orientation = .horizontal; styles.spacing = 10
        let style = NSPopUpButton(); style.addItems(withTitles:LyricsSurfaceStyle.allCases.map(\.rawValue)); style.target = self; style.action = #selector(changeSurface(_:)); styles.addArrangedSubview(style)
        let mode = NSPopUpButton(); mode.addItems(withTitles:["Smooth words","Discrete words","Line timing only"]); mode.target = self; mode.action = #selector(changeMode(_:)); styles.addArrangedSubview(mode)
        let coverProfile = NSPopUpButton(); coverProfile.addItems(withTitles:["Lighter cover","Darker cover"]); coverProfile.target = self; coverProfile.action = #selector(changeCoverProfile(_:)); coverProfile.toolTip = "Cover-blur semantic profile"; styles.addArrangedSubview(coverProfile)
        let coverLayer = NSPopUpButton(); coverLayer.addItems(withTitles:["Cover full","Cover base","Cover highlight"]); coverLayer.target = self; coverLayer.action = #selector(changeCoverLayer(_:)); coverLayer.toolTip = "Render one cover-blur channel"; styles.addArrangedSubview(coverLayer)
        let fixtureButton = NSButton(title:"Complex fixture",target:self,action:#selector(loadComplex)); styles.addArrangedSubview(fixtureButton)
        controls.insertArrangedSubview(styles,at:3)
        let advanced = NSStackView(); advanced.orientation = .horizontal; advanced.spacing = 10
        for (tag,title) in [(10,"Hide active"),(11,"Suppress glow"),(12,"Generic cover"),(13,"Lyric dodge")] {
            let button = NSButton(checkboxWithTitle:title,target:self,action:#selector(advancedOption(_:))); button.tag = tag; advanced.addArrangedSubview(button)
            if tag == 12 { genericCoverButton = button }
        }
        controls.insertArrangedSubview(advanced,at:4)
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
        lyrics.onSeek = { [weak self] in self?.seek($0) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let args = CommandLine.arguments
        let supplied = args.firstIndex(of:"--ttml").flatMap { $0+1<args.count ? URL(fileURLWithPath:args[$0+1]) : nil }
        let local = Bundle.main.resourceURL?.appendingPathComponent("song.ttml")
        let fixture = Bundle.main.resourceURL!.appendingPathComponent("complex.ttml")
        load(supplied ?? (local.flatMap { FileManager.default.fileExists(atPath:$0.path) ? $0 : nil }) ?? fixture)
        if let audio = Bundle.main.resourceURL?.appendingPathComponent("audio.m4a"), FileManager.default.fileExists(atPath:audio.path) { attachAudio(audio) }
        timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.updateControls() } }
        RunLoop.main.add(timer!,forMode:.common)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); lyrics.releaseRenderingResources(); player?.stop() }
    private func makeMenu() {
        let menu = NSMenu(), app = NSMenuItem(); menu.addItem(app); let submenu = NSMenu(); app.submenu = submenu
        submenu.addItem(withTitle:"Quit Native Lyrics Demo",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let transport = NSMenuItem(); menu.addItem(transport); let actions = NSMenu(title:"Playback"); transport.submenu = actions
        let p = actions.addItem(withTitle:"Play / Pause",action:#selector(toggle),keyEquivalent:" "); p.target = self; p.keyEquivalentModifierMask = []
        let f = actions.addItem(withTitle:"Follow current lyrics",action:#selector(follow),keyEquivalent:"f"); f.target = self
        NSApp.mainMenu = menu
    }
    private func load(_ url: URL) {
        do {
            let data = try Data(contentsOf:url); try lyrics.load(ttml:data)
            mediaURL = url; duration = max(1,lyrics.document?.duration ?? 70); slider.maxValue = duration
            player?.stop(); clock.synchronize(time:0,playing:false,host:CACurrentMediaTime())
            titleLabel.stringValue = lyrics.document?.title.isEmpty == false ? lyrics.document!.title : url.deletingPathExtension().lastPathComponent
            updateControls()
        } catch { showError(error) }
    }
    private func attachAudio(_ url: URL) {
        do { player = try AVAudioPlayer(contentsOf:url); player?.prepareToPlay(); player?.pause(); player?.currentTime = 0; duration = max(duration,player?.duration ?? 0); slider.maxValue = duration }
        catch { showError(error) }
    }
    private var time: Double { player?.currentTime ?? clock.time(at:CACurrentMediaTime()) }
    @objc private func toggle() {
        let now = CACurrentMediaTime(), current = time, playing = !clock.isPlaying
        clock.synchronize(time:current,playing:playing,host:now)
        if playing { player?.play() } else { player?.pause() }
        lyrics.synchronize(time:current,playing:playing,hostTime:now); updateControls()
    }
    private func seek(_ time: Double) {
        let value = max(0,min(duration,time)), now = CACurrentMediaTime()
        player?.currentTime = value; clock.synchronize(time:value,playing:clock.isPlaying,host:now)
        lyrics.synchronize(time:value,playing:clock.isPlaying,seek:true,hostTime:now); updateControls()
    }
    @objc private func scrub() { seek(slider.doubleValue) }
    @objc private func back() { seek(time-5) }
    @objc private func forward() { seek(time+5) }
    @objc private func follow() { lyrics.followCurrentLyrics() }
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
    }
    @objc private func changeCoverProfile(_ sender: NSPopUpButton) {
        lyrics.configuration.coverBlurProfile = sender.indexOfSelectedItem == 1 ? .darker : .lighter
    }
    @objc private func changeCoverLayer(_ sender: NSPopUpButton) {
        lyrics.configuration.coverBlurRenderLayer = LyricsRenderLayer.allCases[sender.indexOfSelectedItem]
        if lyrics.configuration.coverBlurRenderLayer != .full {
            lyrics.configuration.coverBlurGenericMode = true
            genericCoverButton?.state = .on
        }
    }
    @objc private func advancedOption(_ sender: NSButton) {
        let enabled = sender.state == .on
        switch sender.tag {
        case 10: lyrics.configuration.coverBlurHideActiveMainLine = enabled
        case 11: lyrics.configuration.coverBlurSuppressEmphasisGlow = enabled
        case 12: lyrics.configuration.coverBlurGenericMode = enabled
        case 13: lyrics.configuration.fullscreenLyricDodgeMode = enabled
        default: break
        }
    }
    @objc private func changeMode(_ sender: NSPopUpButton) { lyrics.configuration.lineTimingOnly = sender.indexOfSelectedItem == 2; lyrics.configuration.highlightMode = sender.indexOfSelectedItem == 1 ? .discrete : .smooth }
    @objc private func loadComplex() { player?.stop(); player = nil; load(Bundle.main.resourceURL!.appendingPathComponent("complex.ttml")) }
    @objc private func fontSize(_ sender: NSSlider) { lyrics.configuration.fontSize = sender.doubleValue }
    @objc private func option(_ sender: NSButton) {
        let enabled = sender.state == .on
        switch sender.tag { case 0: lyrics.configuration.emphasis = enabled; case 1: lyrics.configuration.glow = enabled; case 2: lyrics.configuration.showTranslation = enabled; case 3: lyrics.configuration.showRuby = enabled; default: lyrics.configuration.blur = enabled }
    }
    @objc private func openTTML() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.beginSheetModal(for:window) { [weak self] response in if response == .OK, let url = panel.url { self?.load(url) } } }
    @objc private func openAudio() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.beginSheetModal(for:window) { [weak self] response in if response == .OK, let url = panel.url { self?.attachAudio(url) } } }
    private func updateControls() {
        var current = time
        if current >= duration && clock.isPlaying { current = duration; player?.pause(); clock.synchronize(time:current,playing:false,host:CACurrentMediaTime()) }
        if player != nil && clock.isPlaying { lyrics.synchronize(time:current,playing:true) }
        slider.doubleValue = current; play.title = clock.isPlaying ? "Pause" : "Play"
        func format(_ t: Double) -> String { String(format:"%d:%02d",Int(t)/60,Int(t)%60) }
        clockLabel.stringValue = "\(format(current)) / \(format(duration))"
        if let frame = lyrics.lastFrame {
            let hot = frame.timeline.playing.sorted().map(String.init).joined(separator:",")
            let highlighted = frame.timeline.highlighted.sorted().map(String.init).joined(separator:",")
            status.stringValue = String(format:"%@ · hot %@ · highlight %@ · %@/%@ · %.2f ms/frame · %.1f MB cache · %d layouts",frame.following ? "Following" : "Manual scroll",hot.isEmpty ? "—" : hot,highlighted.isEmpty ? "—" : highlighted,lyrics.configuration.surface.rawValue,lyrics.configuration.effectiveRenderLayer.rawValue,frame.renderMilliseconds,Double(frame.glyphCacheBytes)/1048576,frame.layoutCount)
        }
    }
    private func showError(_ error: Error) { logger.error("\(error.localizedDescription,privacy:.public)"); NSAlert(error:error).beginSheetModal(for:window) }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = DemoController()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
