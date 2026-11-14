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
    func testV2HiddenNodesAndUnsetStyleStayOffTheFrame() throws {
        func node(_ root: String) throws -> SkinCompiledSceneNode {
            try SkinSceneCompiler.compile(JSONDecoder().decode(SkinSceneV2Document.self, from: Data("{\"root\":\(root)}".utf8))).root
        }
        // `visible` alone decides the draw, so a hidden node evaluates nothing else.
        XCTAssertTrue(try node(#"{"type":"shape","visible":"=clock.position > 1","opacity":"=clock.progress"}"#).hidesWithoutTransition)
        // A transition keeps the node mounted, and a variant may show it again.
        XCTAssertFalse(try node(#"{"type":"shape","visible":false,"transition":"fade"}"#).hidesWithoutTransition)
        XCTAssertFalse(try node(#"{"type":"shape","visible":false,"variants":[{"when":"=self.hovered","visible":true}]}"#).hidesWithoutTransition)
        XCTAssertFalse(try node(#"{"type":"shape"}"#).hidesWithoutTransition)
        // Only the style a node can set is applied; effects and keyframes may set any of it.
        let plain = try node(#"{"type":"shape","opacity":0.5,"variants":[{"when":"=self.hovered","scale":1.1}]}"#)
        XCTAssertEqual(plain.styleKeys?.contains("opacity"), true)
        XCTAssertEqual(plain.styleKeys?.contains("scale"), true)
        XCTAssertEqual(plain.styleKeys?.contains("blur"), false)
        XCTAssertNil(try node(#"{"type":"shape","effects":[{"type":"blur","value":4}]}"#).styleKeys)
        // A white glyph tint multiplies to no change and is left off.
        XCTAssertNil(SkinGlyphTransform(.record(["tint": .color(OKLCHColor(lightness: 1, chroma: 0, hue: nil))])).tint)
        XCTAssertNotNil(SkinGlyphTransform(.record(["tint": .color(OKLCHColor(lightness: 0.6, chroma: 0.1, hue: 0.1))])).tint)
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
        // A plain text keeps running only when its glyph motion reads the glyph clock.
        XCTAssertFalse(try node(#"{"type":"text","text":"a","glyphMotion":{"y":"=easeOut(glyph.age / 0.4)"}}"#).pausesWithPlayback)
        XCTAssertTrue(try node(#"{"type":"text","text":"a","glyphMotion":{"y":"=glyph.index * glyph.fontSize * 0.1"}}"#).pausesWithPlayback)
        XCTAssertNil(SkinGlyphOutline(.number(0), fallback: nil))
        // Unchanged writes leave the revision alone, so cached node values survive pointer moves.
        let facts = SkinSceneData()
        facts.set(.theme, ["theme.accent": .number(1)])
        let revision = facts.revision
        facts.set(.theme, ["theme.accent": .number(1)])
        facts.updateHostFacts(["host.pointerIdle": .boolean(false)])
        XCTAssertEqual(facts.revision, revision)
        XCTAssertThrowsError(try node(#"{"type":"text","text":"=glyph.char"}"#))
        XCTAssertThrowsError(try node(#"{"type":"shape","glyphMotion":{"y":1}}"#))

        XCTAssertNoThrow(try node(#"{"type":"text","text":"a","filter":[{"type":"chromatic","amount":2},{"type":"glitch"}],"bloom":12,"outline":{"width":2,"hollow":true}}"#))
        XCTAssertNoThrow(try node(#"{"type":"text","text":"a","filter":[{"type":"fov","distortion":0.25,"chromatic":1.5,"blur":4,"start":0.55}]}"#))
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
        XCTAssertTrue(stage.cameraInputs.time)
        XCTAssertFalse(stage.cameraInputs.always)
        // Per-frame nodes keep their steady values between frames unless they read live clocks.
        XCTAssertTrue(try node(#"{"type":"text","text":"=track.title","opacity":"=oscillate(2)"}"#).cachesSteadyValues)
        XCTAssertFalse(try node(#"{"type":"text","text":"=track.title"}"#).cachesSteadyValues)
        XCTAssertTrue(try node(#"{"type":"text","text":"a","watch":[{"value":"=track.id","initial":true,"do":"skin.reload"}]}"#).watches.first?.initial == true)
        XCTAssertThrowsError(try node(#"{"type":"text","text":"a","watch":[{"value":"=track.id","initial":"=1","do":"skin.reload"}]}"#))
        XCTAssertNoThrow(try node(#"{"type":"text","text":"a","filter":{"type":"custom","library":"fx.metallib","function":"ripple","args":[2,[1,0]]}}"#))
        XCTAssertThrowsError(try node(#"{"type":"text","text":"a","filter":{"type":"custom","library":"fx.metal","function":"ripple"}}"#))
        XCTAssertTrue(try node(#"{"type":"text","text":"a","filter":{"type":"custom","library":"fx.metallib","function":"ripple"}}"#).referencedAssets.contains("fx.metallib"))
        XCTAssertNoThrow(try node(#"{"type":"text","text":"=str(offsets(measureEach(split(\"a b c\", \" \"), 20, \"heavy\"), 4)[1])","extrude":{"depth":6,"angle":30},"shadow":[{"radius":2},{"radius":8}]}"#))
        XCTAssertNoThrow(try node(#"{"type":"particles","lifetime":2,"angle":-30,"spread":10,"trail":0.3,"count":6,"turbulence":40,"wander":0.6,"curve":0.1}"#))
        let comet = try node(#"{"type":"comet","frame":{"x":120,"y":80,"width":600,"height":400},"orbit":[140,90],"progress":"=fract(time)","angle":90,"sweep":-240,"trail":0.16,"size":3,"width":3,"color":"#FFFFFF"}"#)
        XCTAssertEqual(comet.type, "comet")

        // Kinetic layout: every word gets a box, boxes never overlap, the block fits the safe area.
        func words(_ texts: [String]) -> [SkinValue] {
            texts.enumerated().map { .record(["text": .text($0.element), "start": .number(Double($0.offset) * 0.4), "end": .number(Double($0.offset) * 0.4 + 0.4)]) }
        }
        let lines = [words(["IT ", "WAS ", "LIKE"]), words(["we ", "were ", "never ", "meant ", "to ", "be ", "separated"]),
                     words(["宝", "船", "载", "着", "星", "光"]), words(["你"]), [.record(["text": .text("一整行 只有行时间"), "start": .number(0), "end": .number(3)])]]
        // A word's drawn box, turned by its tilt (a rotated word's box is already upright), a
        // little inside its em box so touching neighbours do not count.
        func corners(_ item: SkinValue) -> [CGPoint] {
            let r = item[member: "r"].number(), tilt = (r >= 45 ? r - 90 : r) * .pi / 180
            let hw = item[member: "w"].number() / 2 - 2, hh = item[member: "h"].number() / 2 * 0.86 - 2
            let x = item[member: "x"].number(), y = item[member: "y"].number()
            return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
                CGPoint(x: x + dx * cos(tilt) - dy * sin(tilt), y: y + dx * sin(tilt) + dy * cos(tilt))
            }
        }
        func separated(_ p: [CGPoint], _ q: [CGPoint]) -> Bool {
            for shape in [p, q] {
                for i in 0..<4 {
                    let edge = CGPoint(x: shape[(i + 1) % 4].x - shape[i].x, y: shape[(i + 1) % 4].y - shape[i].y)
                    let axis = CGPoint(x: -edge.y, y: edge.x)
                    let a = p.map { $0.x * axis.x + $0.y * axis.y }, b = q.map { $0.x * axis.x + $0.y * axis.y }
                    if a.max()! <= b.min()! || b.max()! <= a.min()! { return true }
                }
            }
            return false
        }
        var archetypes: [Double: Set<Int>] = [0: [], 1: []]
        for (number, line) in lines.enumerated() {
            for complexity in [0.0, 1.0] {
                for seed in 0..<40 {
                    let result = SkinKineticLayout.layout(line, options: [.number(Double(seed) * 1.618 + Double(number)), .list([]), .number(2000), .number(1000), .number(1.08), .list([.text(""), .text("")]), .text("heavy"), .number(1), .number(complexity)])
                    archetypes[complexity]?.insert(Int(result[member: "archetype"].number()))
                    let items = result[member: "items"].listValue
                    XCTAssertGreaterThanOrEqual(items.count, line.count)
                    let size = result[member: "size"].listValue.map { $0.number() }
                    XCTAssertLessThanOrEqual(size[0], 2001); XCTAssertLessThanOrEqual(size[1], 1001)
                    for item in items {
                        XCTAssertTrue(item[member: "x"].number().isFinite && item[member: "y"].number().isFinite)
                        XCTAssertEqual(hypot(item[member: "ex"].number(), item[member: "ey"].number()), 1, accuracy: 0.01)
                    }
                    for a in items.indices { for b in items.indices where b > a {
                        XCTAssertTrue(separated(corners(items[a]), corners(items[b])),
                                      "family \(result[member: "family"].number()) overlaps \(items[a][member: "t"].textValue) / \(items[b][member: "t"].textValue)")
                    } }
                }
            }
        }
        // Simple lines stay with rows (and the rare vertical hero or cascade); rich lines use every archetype.
        XCTAssertTrue(archetypes[0]!.isSubset(of: [0, 1, 2, 6, 8]), "\(archetypes[0]!)")
        XCTAssertGreaterThanOrEqual(archetypes[1]!.count, 7, "\(archetypes[1]!)")
    }

    @MainActor
    func testV2SceneClockNeverStepsBackWhilePlaying() {
        var clock = SkinPlaybackClock()
        clock.update(position: 10, isPlaying: true, duration: 100, now: 0)
        var last = clock.position(at: 0)
        // Samples arrive late and uneven, as from a 10 Hz timer behind a busy main thread.
        var now = 0.0
        for step in 1...60 {
            now += step % 7 == 0 ? 0.35 : 0.1
            let stale = step % 5 == 0 ? 0.18 : 0.02
            clock.update(position: 10 + now - stale, isPlaying: true, duration: 100, now: now)
            for frame in 0..<12 {
                let value = clock.position(at: now + Double(frame) / 120)
                XCTAssertGreaterThanOrEqual(value, last - 0.0001)
                last = value
            }
        }
        XCTAssertEqual(clock.position(at: now), 10 + now, accuracy: 0.2)
        // A seek lands at once, backwards included.
        clock.update(position: 3, isPlaying: true, duration: 100, now: now, jump: true)
        XCTAssertEqual(clock.position(at: now), 3, accuracy: 0.0001)
    }

    @MainActor
    func testV2MotionSpringsFollowAndPlaybackFlow() throws {
        func program(_ json: String) throws -> SkinSceneProgram {
            try SkinSceneCompiler.compile(JSONDecoder().decode(SkinSceneV2Document.self, from: Data(json.utf8)))
        }
        func node(_ root: String) throws -> SkinCompiledSceneNode { try program("{\"root\":\(root)}").root }
        let data = SkinSceneData()
        func evaluate(_ source: String, _ context: SkinEvaluationContext? = nil) throws -> Double {
            let expression = try SkinExpressionCompiler.compile(source: source, expected: .number, environment: SkinCompileEnvironment())
            return expression.evaluate(context ?? SkinEvaluationContext(data: data)).number()
        }
        // Token springs start at 0, overshoot with bounce, and land at 1; numbers keep the oscillation.
        XCTAssertEqual(try evaluate(#"spring("emphasis", 0)"#), 0)
        XCTAssertGreaterThan(try evaluate(#"spring("emphasis", 0.35)"#), 1)
        XCTAssertEqual(try evaluate(#"spring("emphasis", 3)"#), 1, accuracy: 0.001)
        XCTAssertGreaterThan(try evaluate(#"springVelocity("layout", 0.05)"#), 0)
        XCTAssertEqual(try evaluate("spring(0, 2)"), 1, accuracy: 0.0001)
        var still = SkinEvaluationContext(data: data)
        still.moves = false
        XCTAssertEqual(try evaluate(#"spring("emphasis", 0.1)"#, still), 1)
        // springTo: a spring of a given length and bounce; no bounce never overshoots.
        XCTAssertEqual(try evaluate("springTo(-0.2, 0.8, 0.3)"), 0)
        XCTAssertEqual(try evaluate("springTo(3, 0.8, 0.3)"), 1, accuracy: 0.001)
        XCTAssertGreaterThan(try evaluate("springTo(0.45, 0.8, 0.5)"), 1)
        XCTAssertLessThanOrEqual(try evaluate("springTo(0.45, 0.8, 0)"), 1.0001)
        XCTAssertEqual(try evaluate("springTo(0.05, 0.8, 0.3)", still), 1)

        // A follow spring starts on its target, chases a new one and lands.
        let followers = SkinFollowers()
        var context = SkinEvaluationContext(data: data)
        context.followers = followers
        let site = try SkinExpressionCompiler.compile(source: #"follow(state.x, "control")"#, expected: .number,
                                                      environment: SkinCompileEnvironment(state: ["x": .number]))
        data.setState("x", .number(0))
        context.now = Date.timeIntervalSinceReferenceDate
        XCTAssertEqual(site.evaluate(context).number(), 0)
        data.setState("x", .number(100))
        XCTAssertEqual(site.evaluate(context).number(), 0, accuracy: 0.5)
        context.now += 0.1
        let midway = site.evaluate(context).number()
        XCTAssertTrue(midway > 1 && midway < 100)
        context.now += 3
        XCTAssertEqual(site.evaluate(context).number(), 100, accuracy: 0.001)
        XCTAssertEqual(site.tier, .frame)
        XCTAssertTrue(site.domains.contains(.follow))

        // Inputs: follow springs and scene time rest once settled; free time never does.
        let follower = try node(#"{"type":"shape","scale":"=follow(self.hovered ? 1.1 : 1, \"emphasis\")"}"#)
        XCTAssertTrue(follower.frameInputs.follow)
        XCTAssertTrue(follower.frameInputs.isStill(playing: true, timeMoves: true, following: false))
        XCTAssertFalse(follower.frameInputs.isStill(playing: false, timeMoves: false, following: true))
        let spinner = try node(#"{"type":"shape","rotation":"=spin(10)"}"#)
        XCTAssertFalse(spinner.frameInputs.isStill(playing: false, timeMoves: true, following: false))
        XCTAssertTrue(spinner.frameInputs.isStill(playing: false, timeMoves: false, following: false))
        XCTAssertTrue(try node(#"{"type":"shape","rotation":"=time.free * 10"}"#).frameInputs.always)

        // Scene time rides the playback flow: it coasts a little after a pause, then stands still.
        let flow = SkinSceneData()
        let start = 1000.0
        flow.updateFlow(playing: true, now: start)
        let atPause = flow.time(at: start + 1)
        XCTAssertEqual(atPause, 1, accuracy: 0.001)
        flow.updateFlow(playing: false, now: start + 1)
        XCTAssertTrue(flow.flowMoving)
        XCTAssertTrue(flow.timeMoves(playing: false))
        let later = flow.time(at: start + 6)
        XCTAssertGreaterThan(later - atPause, 0.03)
        XCTAssertLessThan(later - atPause, 0.6)
        XCTAssertEqual(flow.time(at: start + 10), later, accuracy: 0.001)
        XCTAssertEqual(flow.value(forKey: "playback.flow", domain: .time, now: start + 10).number(), 0, accuracy: 0.001)

        // Scene motion: own tokens retune built-in ones; pause modes and names are checked.
        let tuned = try program(#"{"root":{"type":"layer"},"motion":{"pause":"continue","flow":"slam","tokens":{"slam":{"token":"emphasis","duration":0.3,"bounce":0.4}}}}"#)
        XCTAssertEqual(tuned.motion.pause, .continue)
        let slam = SkinMotion.spec(.text("slam"), tokens: .standard, custom: tuned.motion.tokens)
        XCTAssertEqual(slam.duration, 0.3, accuracy: 0.0001)
        XCTAssertEqual(slam.bounce, 0.4, accuracy: 0.0001)
        XCTAssertThrowsError(try program(#"{"root":{"type":"layer"},"motion":{"pause":"hold"}}"#))
        XCTAssertThrowsError(try program(#"{"root":{"type":"layer"},"motion":{"tokens":{"emphasis":{"duration":1}}}}"#))
        XCTAssertThrowsError(try program(#"{"root":{"type":"layer"},"motion":{"flow":"slow"}}"#))
        XCTAssertThrowsError(try program(#"{"root":{"type":"layer"},"motion":{"tokens":{"slam":{"durration":1}}}}"#))
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
        XCTAssertEqual(frames.window, CGRect(origin: .zero, size: size))

        // A window scene's viewport is the area above the App's mini player: artwork fills it,
        // the mini player sits just below, and `window` reaches the bottom edge.
        let content = CGSize(width: 900, height: 600)
        let window = SkinHostLayout.frames(size: content, surface: .window, lyricsVisible: false, presentation: .init())
        XCTAssertEqual(window.artwork, CGRect(origin: .zero, size: content))
        XCTAssertEqual(window.miniPlayer.minY, content.height, accuracy: 0.001)
        XCTAssertEqual(window.window.height, content.height + SkinHostLayout.windowMiniPlayerReserve, accuracy: 0.001)
        XCTAssertLessThanOrEqual(window.miniPlayer.maxY, window.window.maxY)

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
