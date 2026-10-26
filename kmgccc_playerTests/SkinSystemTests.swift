import Foundation
import SwiftUI
import XCTest
@testable import kmgccc_player

final class SkinSystemTests: XCTestCase {
    @MainActor
    func testZIPInstallCopyReplaceReloadRestartAndRemoval() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("installed")
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        let store = SkinPackageStore(catalog: catalog, root: root)
        let manifest = try manifestJSON(id: "test.reading", name: "Reading")
        let archive = try zip(manifest: manifest, in: sandbox)
        let installedID = try await store.importPackage(archive)
        XCTAssertEqual(installedID, "test.reading")
        let installed = try XCTUnwrap(catalog.registeredSkin(for: installedID) as? PackagedSkin)
        guard case .installed(let directory) = installed.origin else { return XCTFail("Missing installation") }
        try FileManager.default.removeItem(at: archive)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("asset.txt"), encoding: .utf8), "resource")
        let copyArchive = try zip(manifest: manifest, in: sandbox)
        let copyID = try await store.importPackage(copyArchive, disposition: .copy)
        XCTAssertNotEqual(copyID, installedID)
        XCTAssertNotNil(catalog.registeredSkin(for: installedID))

        let upgraded = try zip(manifest: manifestJSON(id: installedID, name: "Updated"), in: sandbox)
        let replacedID = try await store.importPackage(upgraded, disposition: .replace)
        XCTAssertEqual(replacedID, installedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let replaced = try XCTUnwrap(catalog.registeredSkin(for: installedID) as? PackagedSkin)
        guard case .installed(let currentDirectory) = replaced.origin else { return XCTFail("Missing replacement") }
        let revision = catalog.revision(for: installedID)
        try Data("{broken".utf8).write(to: currentDirectory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.reloadPackage(installedID))
        XCTAssertEqual(catalog.revision(for: installedID), revision)
        XCTAssertEqual(catalog.registeredSkin(for: installedID)?.name, "Updated")
        try manifestJSON(id: installedID, name: "Reloaded").write(to: currentDirectory.appendingPathComponent("manifest.json"))
        try store.reloadPackage(installedID)
        XCTAssertGreaterThan(catalog.revision(for: installedID), revision)
        XCTAssertEqual(catalog.registeredSkin(for: installedID)?.name, "Reloaded")

        let exported = sandbox.appendingPathComponent("export.zip")
        try await store.exportPackage(try XCTUnwrap(catalog.registeredSkin(for: installedID)), to: exported)
        let exportedManifest = try await store.inspect(exported)
        XCTAssertEqual(exportedManifest.descriptor.name, "Reloaded")
        let restarted = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: restarted.components)
        SkinPackageStore(catalog: restarted, root: root).loadInstalled()
        XCTAssertEqual(restarted.registeredSkin(for: installedID)?.name, "Reloaded")
        XCTAssertNotNil(restarted.registeredSkin(for: copyID))
        try store.removePackage(installedID)
        XCTAssertNil(catalog.registeredSkin(for: installedID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentDirectory.path))
    }

    @MainActor
    func testInvalidReplacementPreservesInstalledDefinitionAndResources() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        let store = SkinPackageStore(catalog: catalog, root: sandbox.appendingPathComponent("installed"))
        let archive = try zip(manifest: manifestJSON(id: "test.replacement", name: "Original"), in: sandbox)
        let id = try await store.importPackage(archive)
        let original = try XCTUnwrap(catalog.registeredSkin(for: id) as? PackagedSkin)
        let revision = catalog.revision(for: id)
        let invalid = try zip(manifest: Data("{\"descriptor\":{\"id\":\"test.replacement\",\"name\":\"Invalid\"}}".utf8), in: sandbox)
        do {
            _ = try await store.importPackage(invalid, disposition: .replace)
            XCTFail("Blank scenes must not replace a usable installation")
        } catch {}
        XCTAssertEqual(catalog.revision(for: id), revision)
        XCTAssertEqual(catalog.registeredSkin(for: id)?.name, "Original")
        if case .installed(let directory) = original.origin {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("asset.txt").path))
        }
    }

    @MainActor
    func testBundledCollisionAlwaysCopiesAndBundledRemovalIsRejected() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        catalog.registerBundled(ClassicLEDSkin())
        let store = SkinPackageStore(catalog: catalog, root: sandbox.appendingPathComponent("installed"))
        let archive = try zip(manifest: manifestJSON(id: ClassicLEDSkin.id, name: "Copy"), in: sandbox)
        let id = try await store.importPackage(archive, disposition: .replace)
        XCTAssertNotEqual(id, ClassicLEDSkin.id)
        XCTAssertThrowsError(try store.removePackage(ClassicLEDSkin.id))
        XCTAssertNotNil(catalog.registeredSkin(for: ClassicLEDSkin.id))
    }

    @MainActor
    func testAuthorParameterUpgradeAndMalformedRange() throws {
        let range = SkinParameterDefinition(id: "amount", title: "Amount", defaultValue: .number(0.5), control: .range(min: 0, max: 1, step: 0.1))
        XCTAssertEqual(range.resolvedValue(.number(10)), .number(1))
        XCTAssertEqual(range.resolvedValue(.text("old type")), .number(0.5))
        let choice = SkinParameterDefinition(id: "style", title: "Style", defaultValue: .text("new"), control: .choice([.init(id: "new", title: "New")]))
        XCTAssertEqual(choice.resolvedValue(.text("removed")), .text("new"))
        let invalid = SkinParameterDefinition(id: "invalid", title: "Invalid", defaultValue: .number(0), control: .range(min: 2, max: 1, step: 0))
        XCTAssertThrowsError(try invalid.validateDefinition())
    }

    @MainActor
    func testPartialDescriptorOverridesAndAdaptiveLyricsCount() throws {
        let data = Data("""
        {"formatVersion":2,"hostAPIVersion":2,"descriptor":{"id":"test.adaptive","name":"Adaptive","audio":{"fullscreen":"off"},"presentation":{"lyricsBackdrop":"mesh"}},
         "scene":{"root":{"id":"root","type":"switch","cases":[
          {"id":"wide","type":"lyrics","when":"=viewport.width >= 720"}],
          "default":{"id":"compact","type":"lyrics"}}}}
        """.utf8)
        let manifest = try JSONDecoder().decode(SkinPackageManifest.self, from: data)
        try manifest.validateDefinition()
        let program = try SkinSceneCompiler.compile(XCTUnwrap(manifest.sceneV2))
        XCTAssertEqual(program.nodeCount, 3)
        XCTAssertEqual(manifest.descriptor.presentation.lyricsBackdrop, .mesh)
        XCTAssertTrue(manifest.descriptor.audio.supportsMiniPlayerVisualization)
        let roundTrip = try JSONDecoder().decode(SkinPackageManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(roundTrip.hostAPIVersion, 2)
    }

    @MainActor
    func testV2ExpressionsSeparateStaticAndFrameDependencies() throws {
        let environment = SkinCompileEnvironment()
        let constant = try SkinExpressionCompiler.compile(.text("=2 + 3 * 4"), expected: .number, environment: environment)
        XCTAssertEqual(constant.tier, .constant)
        XCTAssertEqual(constant.constantValue, .number(14))
        let stable = try SkinExpressionCompiler.compile(.text("=track.title"), expected: .text, environment: environment)
        XCTAssertEqual(stable.tier, .change)
        XCTAssertEqual(stable.domains, [.track])
        let frame = try SkinExpressionCompiler.compile(.text("=clock.progress + audio.bass"), expected: .number, environment: environment)
        XCTAssertEqual(frame.tier, .frame)
        XCTAssertEqual(frame.domains, [.clock, .audio])
        XCTAssertThrowsError(try SkinExpressionCompiler.compile(.text("=track.titel"), expected: .text, environment: environment))
    }

    @MainActor
    func testV2TemplateAndCompilerErrorsHaveSourcePaths() throws {
        func document(_ json: String) throws -> SkinSceneV2Document { try JSONDecoder().decode(SkinSceneV2Document.self, from: Data(json.utf8)) }
        let valid = try document("""
        {"components":{"label":{"type":"text","text":"=props.title"}},"root":{"type":"use","name":"label","props":{"title":"=track.title"}}}
        """)
        let program = try SkinSceneCompiler.compile(valid)
        XCTAssertTrue(program.domains.contains(.track))
        let invalid = try document("""
        {"root":{"type":"text","text":"=track.titel"}}
        """)
        XCTAssertThrowsError(try SkinSceneCompiler.compile(invalid, file: "reading.json")) { error in
            XCTAssertTrue(error.localizedDescription.contains("reading.json $.scene.root.text"))
        }
        XCTAssertThrowsError(try SkinSceneCompiler.compile(valid, requires: ["unknown@1"]))
        let cyclic = try document("""
        {"components":{"a":{"type":"use","name":"a"}},"root":{"type":"use","name":"a"}}
        """)
        XCTAssertThrowsError(try SkinSceneCompiler.compile(cyclic))
    }

    @MainActor
    func testV2NativeLyricsCannotRepeatOrAppearTwice() throws {
        for root in [
            #"{"type":"layer","children":[{"type":"lyrics"},{"type":"lyrics"}]}"#,
            #"{"type":"repeat","items":[1,2],"template":{"type":"lyrics"}}"#
        ] {
            let document = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("{\"root\":\(root)}".utf8))
            XCTAssertThrowsError(try SkinSceneCompiler.compile(document))
        }
    }

    @MainActor
    func testV2LyricClockAndSeekOffsetHaveDifferentSemantics() {
        let data = SkinSceneData()
        data.clock.seekOffset = 0.4
        data.clock.lyricsOffset = 0.15
        data.clock.update(position: 10, isPlaying: true, duration: 100, now: 20)
        data.clock.updateLyrics(position: 9.85, isPlaying: false, now: 20)
        XCTAssertEqual(data.clock.position(at: 21), 11, accuracy: 0.0001)
        XCTAssertEqual(data.clock.lyricsTime(at: 21), 9.85, accuracy: 0.0001)
        XCTAssertEqual(data.clock.seekOffset, 0.4)
    }

    @MainActor
    func testV2ContractFactoriesAndResourceBoundaries() throws {
        let catalog = SkinComponentCatalog()
        NativeSkinComponents.register(in: catalog)
        XCTAssertTrue(SkinComponentContract.ids.allSatisfy { catalog.contains($0) })
        let root = URL(fileURLWithPath: "/tmp/skin-package-tests")
        XCTAssertThrowsError(try SkinResourceResolver.resolve("../secret", root: root))
        XCTAssertThrowsError(try SkinResourceResolver.resolve("/absolute", root: root))
        XCTAssertEqual(try SkinResourceResolver.resolve("images/cover.png", root: root).lastPathComponent, "cover.png")
        let parameter = SkinParameterDefinition(id: "color", title: "Color", defaultValue: .text("#123456"), control: .color)
        try parameter.validateDefinition()
        XCTAssertEqual(parameter.resolvedValue(.text("invalid")), .text("#123456"))
        for name in SkinBuiltinSceneTemplates.names {
            _ = try SkinSceneCompiler.compile(XCTUnwrap(SkinBuiltinSceneTemplates.document(name)))
        }
    }

    @MainActor
    func testV2CompilerBudgetsSuggestionsAndAuthorInputs() throws {
        func compile(_ root: String) throws -> SkinSceneProgram {
            try SkinSceneCompiler.compile(JSONDecoder().decode(SkinSceneV2Document.self, from: Data("{\"root\":\(root)}".utf8)))
        }
        // A dynamic repeat counts as 1024 cells unless the author bounds it.
        let pair = #"{"type":"row","children":[{"type":"text","text":"=item.text"},{"type":"text","text":"=index"}]}"#
        XCTAssertThrowsError(try compile(#"{"type":"repeat","items":"=lyrics.lines","template":\#(pair)}"#))
        XCTAssertNoThrow(try compile(#"{"type":"repeat","items":"=lyrics.lines","limit":300,"template":\#(pair)}"#))
        XCTAssertThrowsError(try compile(#"{"type":"repeat","items":"=lyrics.lines","limit":"=1","template":\#(pair)}"#))

        XCTAssertThrowsError(try compile(#"{"type":"text","txet":"a"}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("是否指 text"))
        }
        XCTAssertThrowsError(try compile(#"{"type":"component","component":"artwork.clasicFrame"}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("artwork.classicFrame"))
        }
        XCTAssertThrowsError(try compile(#"{"type":"lyrics","props":{"fontSise":30}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("fontSize"))
        }
        XCTAssertNoThrow(try compile(##"{"type":"lyrics","props":{"fontSize":30,"textColor":"#FFFFFF"}}"##))
        XCTAssertThrowsError(try compile(#"{"type":"shader","path":"a.metal","function":"=track.title"}"#))
        XCTAssertNoThrow(try compile(#"{"type":"component","component":"builtin.coverLed.artwork"}"#))
        XCTAssertThrowsError(try compile(#"{"type":"component","component":"builtin.unknown.artwork"}"#))
    }

    @MainActor
    func testV2NodesPauseWithPlaybackOnlyForPlaybackDrivenInputs() throws {
        func node(_ root: String) throws -> SkinCompiledSceneNode {
            try SkinSceneCompiler.compile(JSONDecoder().decode(SkinSceneV2Document.self, from: Data("{\"root\":\(root)}".utf8))).root
        }
        let disc = try node(#"{"type":"shape","rotation":"=clock.position * 18"}"#)
        XCTAssertEqual(disc.tier, .frame)
        XCTAssertTrue(disc.pausesWithPlayback)
        XCTAssertFalse(disc.tracksPointer)
        XCTAssertFalse(try node(#"{"type":"shape","rotation":"=spin(10)"}"#).pausesWithPlayback)
        XCTAssertFalse(try node(#"{"type":"shader","path":"a.metal"}"#).pausesWithPlayback)
        XCTAssertTrue(try node(#"{"type":"spectrum"}"#).pausesWithPlayback)
        XCTAssertTrue(try node(#"{"type":"shape","scale":1,"variants":[{"when":"=self.hovered","scale":1.1}]}"#).tracksPointer)
        XCTAssertTrue(try node(#"{"type":"text","text":"a"}"#).domains.contains(.theme))
    }

    @MainActor
    func testV2GlyphMotionFiltersAndCamera() throws {
        func node(_ root: String) throws -> SkinCompiledSceneNode {
            try SkinSceneCompiler.compile(JSONDecoder().decode(SkinSceneV2Document.self, from: Data("{\"root\":\(root)}".utf8))).root
        }
        // `glyph` is a local of glyphMotion only, and glyphMotion is not a node value.
        let wave = try node(#"{"type":"text","text":"a","glyphMotion":{"y":"=sin(time - glyph.index) * easeOut(glyph.age / 0.4)"}}"#)
        XCTAssertFalse(wave.pausesWithPlayback)
        XCTAssertNil(wave.values(SkinEvaluationContext(data: SkinSceneData()))["glyphMotion"])
        XCTAssertTrue(try node(#"{"type":"lyricLine","glyphMotion":{"opacity":"=glyph.progress"}}"#).pausesWithPlayback)
        XCTAssertThrowsError(try node(#"{"type":"text","text":"=glyph.char"}"#))
        XCTAssertThrowsError(try node(#"{"type":"shape","glyphMotion":{"y":1}}"#))

        XCTAssertNoThrow(try node(#"{"type":"text","text":"a","filter":[{"type":"chromatic","amount":2},{"type":"glitch"}],"bloom":12,"outline":{"width":2,"hollow":true}}"#))
        XCTAssertThrowsError(try node(#"{"type":"text","text":"a","filter":{"type":"chromatc"}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("chromatic"))
        }
        XCTAssertNoThrow(try node(#"{"type":"layer","camera":{"x":"=sin(time) * 20","zoom":1.1},"children":[{"type":"shape","depth":2,"stroke":{"width":1},"trimEnd":0.5}]}"#))
        XCTAssertThrowsError(try node(#"{"type":"row","camera":{"zoom":1.1}}"#))
        XCTAssertFalse(try node(#"{"type":"fog","colors":["=theme.artBackgroundPrimary","=theme.accent"]}"#).pausesWithPlayback)
        XCTAssertNoThrow(try node(#"{"type":"lyricLine","glyphMotion":{"opacity":"=easeOut(glyph.age / motion.emphasis)"}}"#))

        // A per-frame camera keeps its layer off the display timeline; its children follow on their own.
        let stage = try node(#"{"type":"layer","camera":{"x":"=sin(time) * 20"},"children":[{"type":"repeat","layout":"free","items":[1,2],"template":{"type":"text","text":"=str(item)","depth":"=index"}}]}"#)
        XCTAssertNotEqual(stage.tier, .frame)
        XCTAssertFalse(stage.cameraPausesWithPlayback)
        // Per-frame nodes keep their steady values between frames unless they read live clocks.
        XCTAssertTrue(try node(#"{"type":"text","text":"=track.title","opacity":"=oscillate(2)"}"#).cachesSteadyValues)
        XCTAssertFalse(try node(#"{"type":"text","text":"=track.title"}"#).cachesSteadyValues)
        XCTAssertTrue(try node(#"{"type":"text","text":"a","watch":[{"value":"=track.id","initial":true,"do":"skin.reload"}]}"#).watches.first?.initial == true)
        XCTAssertThrowsError(try node(#"{"type":"text","text":"a","watch":[{"value":"=track.id","initial":"=1","do":"skin.reload"}]}"#))
        XCTAssertNoThrow(try node(#"{"type":"text","text":"a","filter":{"type":"custom","library":"fx.metallib","function":"ripple","args":[2,[1,0]]}}"#))
        XCTAssertThrowsError(try node(#"{"type":"text","text":"a","filter":{"type":"custom","library":"fx.metal","function":"ripple"}}"#))
        XCTAssertTrue(try node(#"{"type":"text","text":"a","filter":{"type":"custom","library":"fx.metallib","function":"ripple"}}"#).referencedAssets.contains("fx.metallib"))
        XCTAssertNoThrow(try node(#"{"type":"text","text":"=str(offsets(measureEach(split(\"a b c\", \" \"), 20, \"heavy\"), 4)[1])","extrude":{"depth":6,"angle":30},"shadow":[{"radius":2},{"radius":8}]}"#))
        XCTAssertNoThrow(try node(#"{"type":"particles","lifetime":2,"angle":-30,"spread":10,"trail":0.3,"count":6}"#))
    }

    @MainActor
    func testV2TemplatesFollowHostLayoutAndMiniPlayerSections() throws {
        // The fullscreen host's bar is 1150 pt on its 1470 × 923 canvas.
        let size = CGSize(width: 1470 * 2, height: 923 * 2)
        let frames = SkinHostLayout.frames(size: size, surface: .fullscreen, lyricsVisible: true, presentation: .init())
        XCTAssertEqual(frames.scale, 2, accuracy: 0.001)
        XCTAssertEqual(frames.miniPlayer.width, 1150 * 2, accuracy: 0.5)
        XCTAssertEqual(frames.miniPlayer.maxY, size.height - 72 * 2, accuracy: 0.5)
        XCTAssertGreaterThan(frames.lyrics.minX, frames.artwork.minX)
        let hidden = SkinHostLayout.frames(size: size, surface: .fullscreen, lyricsVisible: false, presentation: .init())
        XCTAssertGreaterThan(hidden.artwork.width, frames.artwork.width)

        let metrics = FullscreenMiniPlayerLayoutMetrics(scale: 1)
        XCTAssertEqual(metrics.containerWidth(for: .all), metrics.minimumExpandedContainerWidth, accuracy: 0.001)
        XCTAssertLessThan(metrics.containerWidth(for: [.trackInfo, .transport]), metrics.containerWidth(for: .all))

        for name in SkinBuiltinSceneTemplates.names {
            let components = try XCTUnwrap(SkinBuiltinSceneTemplates.program(name)).root.componentNames
            XCTAssertTrue(components.isSuperset(of: ["background.host", "lyrics.native", "behavior.autoHide", "control.miniPlayer"]), name)
            XCTAssertEqual(components.contains { $0.hasSuffix(".artwork") }, name != "coverGradientBlur", name)
        }
    }

    @MainActor
    func testV2LyricsShorthandsAndAdaptiveNodes() throws {
        let document = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("""
        {"root":{"type":"layer","children":[
          {"type":"component","component":"lyrics.native","props":{"highlight":"discrete","hierarchy":"brightness","userSettings":["font"]}},
          {"type":"lyricLine","highlightColor":"#FFFFFF","adaptive":true}
        ]}}
        """.utf8))
        let program = try SkinSceneCompiler.compile(document)
        XCTAssertEqual(program.root.lyricsUserSettings, ["font"])
        XCTAssertTrue(program.root.readsBackdrop)
        XCTAssertFalse(try XCTUnwrap(SkinBuiltinSceneTemplates.program("classicLED")).root.readsBackdrop)
        XCTAssertTrue(try XCTUnwrap(SkinBuiltinSceneTemplates.program("coverGradientBlur")).root.readsBackdrop)

        var configuration = NativeLyricsConfigurationMapper.base(role: .fullscreen)
        configuration.fontSize = 50
        configuration.highlightMode = .discrete
        NativeLyricsConfigurationMapper.apply(
            ["userSettings": "none", "activeColor": "#FFFFFF", "hierarchy": "opacity", "inactiveLevel": 0.4],
            to: &configuration, role: .fullscreen
        )
        XCTAssertEqual(configuration.fontSize, 32)
        XCTAssertEqual(configuration.highlightMode, .smooth)
        XCTAssertEqual(configuration.palette.mainInactive.alpha, 0.4, accuracy: 0.001)
        XCTAssertEqual(configuration.palette.mainInactive.red, 1, accuracy: 0.001)

        NativeLyricsConfigurationMapper.apply(["activeColor": "#FFFFFF", "hierarchy": "brightness", "inactiveLevel": 0.4],
                                              to: &configuration, role: .fullscreen)
        XCTAssertEqual(configuration.palette.mainInactive.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(configuration.palette.mainInactive.red, 0.4, accuracy: 0.001)
    }

    @MainActor
    func testV2AuthoringPrimitivesCompileAndEvaluate() throws {
        let document = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("""
        {"root":{"type":"layer","children":[
          {"type":"gradient","mode":"radial","radius":0.6,"stops":[{"color":"#000000","at":0},{"color":"#FFFFFF","at":1}]},
          {"type":"text","text":"a","design":"serif","italic":true,"tracking":2,"lineSpacing":4,"minScale":0.5,"measure":true,
           "visible":"=playback.isPlaying","transition":"fade+fromBottom"},
          {"type":"lyricLine","highlightColor":"#FFFFFF","highlightStyle":"word","mode":"translation"},
          {"type":"shape","color":"=readable(hex('#202020'))"}
        ]}}
        """.utf8))
        XCTAssertNoThrow(try SkinSceneCompiler.compile(document))
        XCTAssertGreaterThan(SkinFunctions.contrastRatio(.white, .black), 20)

        let definition = try JSONDecoder().decode(SkinParameterDefinition.self, from: Data("""
        {"id":"a","title":"A","defaultValue":true,"control":{"type":"toggle"},"section":"歌词"}
        """.utf8))
        XCTAssertEqual(definition.section, "歌词")
    }

    @MainActor
    func testV2PlayerMenuLikeStateAndOutputAreOpenToAuthors() throws {
        let document = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("""
        {"root":{"type":"layer","children":[
          {"type":"component","component":"menu.player","props":{"trigger":"click","include":["track","order","output"]},
           "children":[{"type":"symbol","name":"ellipsis"}]},
          {"type":"component","component":"control.dislike","props":{"symbol":"hand.thumbsdown"}},
          {"type":"component","component":"control.outputDevice","props":{"showsName":false}},
          {"type":"lyricLine","key":"=lyrics.currentIndex","transition":"fade+fromBottom"},
          {"type":"text","text":"=track.audio.isHiRes ? 'Hi-Res' : output.name",
           "visible":"=like.isDisliked || like.state == 'none' || library.canEditTrack || track.hasMusicInfo",
           "on":{"tap":[
             {"do":"setLike","value":"liked"},{"do":"toggleDislike"},{"do":"playlist.new"},{"do":"musicInfo.open"},
             {"do":"artist.show"},{"do":"album.show"},{"do":"output.select","value":""},
             {"do":"queue.show"},{"do":"queue.hide"},{"do":"lyrics.show"},{"do":"lyrics.hide"}]}}
        ]}}
        """.utf8))
        XCTAssertNoThrow(try SkinSceneCompiler.compile(document, requires: ["like.state@1", "output@1", "track.audio@1", "library.playlists@1"]))
        XCTAssertThrowsError(try SkinSceneCompiler.compile(document, requires: ["output@2"]))
    }

    @MainActor
    func testV2SceneDrawnQueueCompilesWithinNodeBudget() throws {
        let row = """
        {"type":"layer","on":{"tap":{"do":"queue.play","value":"=item.index"}},"children":[
          {"type":"artwork","track":"=item.id"},{"type":"text","text":"=item.title"},{"type":"text","text":"=item.artist"},
          {"type":"text","text":"=formatTime(item.duration)"},{"type":"symbol","name":"speaker.wave.2.fill","visible":"=item.isCurrent"}]}
        """
        let document = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("""
        {"root":{"type":"layer","controls":["queue"],"children":[
          {"type":"gradient","mode":"elliptical","radius":0.5},
          {"type":"text","text":"=concat('-', formatTime(max(0, playback.duration - (state.scrubbing ? 1 : clock.position))))"},
          {"type":"scroll","scrollTo":"=queue.currentIndex","visible":"=host.queueVisible && queue.available",
           "children":[{"type":"repeat","items":"=queue.items","limit":1024,"template":\(row)}]}
        ]},"state":{"scrubbing":false}}
        """.utf8))
        XCTAssertNoThrow(try SkinSceneCompiler.compile(document, requires: ["host@1", "clock.playback@1", "queue.items@1"]))
        // Outside a scroll every cell is built, so the same rows exceed the budget.
        let eager = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("""
        {"root":{"type":"layer","children":[{"type":"repeat","items":"=queue.items","limit":1024,"template":\(row)}]}}
        """.utf8))
        XCTAssertThrowsError(try SkinSceneCompiler.compile(eager, requires: ["queue.items@1"]))
    }

    @MainActor
    func testV2SceneMotionEnterAndGroupCompile() throws {
        let document = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("""
        {"root":{"type":"layer","controls":["playPause","previous","next"],
          "enter":{"type":"fade+scale","scale":0.98,"token":"backgroundTransition","delay":0.1},
          "children":[
            {"type":"layer","group":true,"motion":{"speed":1.5,"emphasis":{"bounce":0.3},"control":{"stiffness":320,"damping":24}},
             "children":[
               {"type":"component","component":"control.previous","props":{"size":40,"symbolSize":36}},
               {"type":"component","component":"control.playPause","props":{"size":40,"color":"#FFFFFF","blendMode":"plusLighter"}},
               {"type":"component","component":"control.next","props":{"size":40}},
               {"type":"gradient","mode":"elliptical","blendMode":"plusLighter",
                "animation":{"token":"layout","stiffness":200,"mass":1.2,"damping":18}}
             ]}
          ]}}
        """.utf8))
        XCTAssertNoThrow(try SkinSceneCompiler.compile(document, requires: []))
    }

    @MainActor
    func testPointerIdleLayerStaysOffTheFrameTimeline() throws {
        // A layer of controls hidden by pointer idleness would otherwise rebuild every frame.
        let document = try JSONDecoder().decode(SkinSceneV2Document.self, from: Data("""
        {"root":{"type":"layer","visible":"=!host.pointerIdle","transition":"fade","children":[
          {"type":"component","component":"control.playPause"},
          {"type":"text","text":"=concat('', host.pointerIdleTime)"}]}}
        """.utf8))
        let program = try SkinSceneCompiler.compile(document, requires: ["host@1", "host.pointer@1"])
        let rootTierIsBeforeFrame = program.root.tier < .frame
        let lastChildIsFrameTier = program.root.children.last?.tier == .frame
        XCTAssertTrue(rootTierIsBeforeFrame)
        XCTAssertTrue(lastChildIsFrameTier)
    }

    @MainActor
    func testUnsupportedVisualizationKeepsAuthorsSelectedSkin() {
        let id = "test.skin." + UUID().uuidString
        var descriptor = SkinDescriptor(id: id, name: "Custom", detail: "", systemImage: "paintpalette")
        descriptor.audio.supportsMiniPlayerVisualization = false
        descriptor.audio.supportsEmbeddedVisualizer = false
        let catalog = SkinRegistry.catalog
        catalog.install(PackagedSkin(
            manifest: .init(descriptor: descriptor, scene: .init(root: .component("title", "native.trackInfo"))),
            origin: .installed(FileManager.default.temporaryDirectory.appendingPathComponent(id)), renderer: nil
        ))
        defer { catalog.removeInstalled(id) }
        let configuration = FullscreenPresentationConfiguration(skinID: id, visualizerMode: .miniPlayerSpectrum)
        XCTAssertEqual(configuration.skinID, id)
        XCTAssertEqual(configuration.visualizerMode, .off)
    }

    @MainActor
    func testSameIDRevisionInvalidatesHostWork() async {
        let session = SkinSession()
        session.activate("test", revision: 1)
        let generation = session.generation
        session.activate("test", revision: 1)
        XCTAssertEqual(session.generation, generation)
        session.activate("test", revision: 2)
        XCTAssertGreaterThan(session.generation, generation)
        let refreshed = session.generation
        session.deactivate()
        XCTAssertGreaterThan(session.generation, refreshed)
    }

    @MainActor
    func testSceneResourcesReleaseExactlyOnceOnReloadAndExit() {
        let session = SkinSession()
        session.activate("test", revision: 1)
        var releases = 0
        session.registerCleanup { releases += 1 }
        session.activate("test", revision: 2)
        XCTAssertEqual(releases, 1)
        let removed = session.registerCleanup { releases += 100 }
        session.removeCleanup(removed)
        session.registerCleanup { releases += 1 }
        session.deactivate()
        session.deactivate()
        XCTAssertEqual(releases, 2)
    }

    @MainActor
    func testRetiringLyricsSceneCannotClearSuccessorConfiguration() {
        let manager = NativeLyricsSurfaceManager.shared
        let role = LyricsSurfaceRole.batchPreview
        let old = UUID(), current = UUID()
        let baseline = manager.configurationForConsumers(role: role)
        defer {
            manager.clearSceneConfigurationOverride(for: role, owner: current)
            manager.applyConfiguration(baseline, for: role)
        }
        manager.setSceneConfigurationOverride("{\"fontSize\":44}", for: role, owner: old)
        manager.setSceneConfigurationOverride("{\"fontSize\":70}", for: role, owner: current)
        manager.clearSceneConfigurationOverride(for: role, owner: old)
        XCTAssertEqual(manager.configurationForConsumers(role: role).fontSize, 70)
        manager.clearSceneConfigurationOverride(for: role, owner: current)
        XCTAssertEqual(manager.configurationForConsumers(role: role).fontSize, baseline.fontSize)
    }

    @MainActor
    private func manifestJSON(id: String, name: String) throws -> Data {
        let manifest = SkinPackageManifest(
            descriptor: .init(id: id, name: name, detail: "", systemImage: "text.alignleft"),
            scene: .init(root: .component("title", "native.trackInfo"))
        )
        return try JSONEncoder().encode(manifest)
    }

    private func zip(manifest: Data, in sandbox: URL) throws -> URL {
        let source = sandbox.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try manifest.write(to: source.appendingPathComponent("manifest.json"))
        try Data("resource".utf8).write(to: source.appendingPathComponent("asset.txt"))
        let archive = sandbox.appendingPathComponent(UUID().uuidString + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, archive.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }
}
