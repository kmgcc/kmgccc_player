import XCTest
@testable import kmgccc_player

@MainActor
final class AudioDSPScriptControllerTests: XCTestCase {
    func testGetDraftDoesNotCreateDraftFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodeID = UUID()
        let controller = DSPScriptController(draftStore: DSPScriptDraftStore(rootURL: root))

        let draft = try await controller.getDraft(nodeID: nodeID)

        XCTAssertNil(draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDraftCASConflictKeepsSavedSourceAndRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodeID = UUID()
        let controller = DSPScriptController(draftStore: DSPScriptDraftStore(rootURL: root))
        let initial = try await controller.updateDraft(
            nodeID: nodeID,
            languageVersion: 1,
            source: DSPScriptNodeParameters.defaultSource,
            values: ["gainDB": 1]
        )

        do {
            _ = try await controller.updateDraft(
                nodeID: nodeID,
                languageVersion: 1,
                source: "process { output = input; }",
                values: [:],
                expectedDraftRevision: "stale-revision"
            )
            XCTFail("A stale draft revision must fail.")
        } catch let error as DSPScriptDraftStoreError {
            XCTAssertEqual(error, .revisionConflict)
        }

        let reloaded = try await controller.getDraft(nodeID: nodeID)
        XCTAssertEqual(reloaded?.revisionString, initial.revisionString)
        XCTAssertEqual(reloaded?.source, initial.source)
        XCTAssertEqual(reloaded?.values, initial.values)
    }

    func testCompilationReflectsParametersAndBindsTheRequestedFormat() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodeID = UUID()
        let format = stereoFormat
        let controller = DSPScriptController(draftStore: DSPScriptDraftStore(rootURL: root))
        let draft = try await controller.updateDraft(
            nodeID: nodeID,
            languageVersion: 1,
            source: DSPScriptNodeParameters.defaultSource,
            values: ["gainDB": 3]
        )

        let compiled = try await controller.compileDraft(
            nodeID: nodeID,
            format: format,
            expectedDraftRevision: draft.revisionString
        )

        XCTAssertEqual(compiled.format, format)
        XCTAssertEqual(compiled.parameters.map(\.name), ["gainDB"])
        XCTAssertEqual(compiled.parameterValues["gainDB"], 3)
        XCTAssertEqual(compiled.latencyFrames, 0)
        XCTAssertEqual(controller.activityByNodeID[nodeID]?.compilePhase, .succeeded)

        let fixtureResult = try await controller.testDraft(
            nodeID: nodeID,
            format: format,
            fixture: .impulse(durationSeconds: 0.05, amplitude: 0.25),
            expectedDraftRevision: draft.revisionString
        )
        XCTAssertEqual(fixtureResult.fixtureName, "impulse")
        XCTAssertEqual(fixtureResult.frames, 2_400)
        XCTAssertEqual(controller.activityByNodeID[nodeID]?.testPhase, .succeeded)
    }

    func testFailedDraftCompileDoesNotChangeAppliedConfiguration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let presetRoot = root.appendingPathComponent("Presets", isDirectory: true)
        let draftRoot = root.appendingPathComponent("Drafts", isDirectory: true)
        let owner = AudioDSPController(store: DSPPresetStore(rootURL: presetRoot))
        await owner.ensureLoaded()
        let nodeID = UUID()
        var candidate = owner.configuration
        candidate.nodes.append(.script(nodeID: nodeID))
        _ = try owner.apply(candidate)
        owner.commitPendingApply()
        let appliedRevision = owner.revisionString
        let appliedConfiguration = owner.configuration

        let scriptController = DSPScriptController(draftStore: DSPScriptDraftStore(rootURL: draftRoot))
        scriptController.bind(dspController: owner)
        let draft = try await scriptController.updateDraft(
            nodeID: nodeID,
            languageVersion: 1,
            source: "process { output = input * ; }",
            values: [:]
        )
        do {
            _ = try await scriptController.compileDraft(
                nodeID: nodeID,
                format: stereoFormat,
                expectedDraftRevision: draft.revisionString
            )
            XCTFail("Invalid source should not compile.")
        } catch is DSPScriptCompilationError {
            XCTAssertEqual(scriptController.activityByNodeID[nodeID]?.compilePhase, .failed)
            XCTAssertFalse(scriptController.activityByNodeID[nodeID]?.compileDiagnostics.isEmpty ?? true)
        }

        scriptController.clearDiagnostics()
        XCTAssertEqual(scriptController.activityByNodeID[nodeID]?.compilePhase, .failed)
        XCTAssertTrue(scriptController.activityByNodeID[nodeID]?.compileDiagnostics.isEmpty ?? false)

        XCTAssertEqual(owner.revisionString, appliedRevision)
        XCTAssertEqual(owner.configuration, appliedConfiguration)
    }

    func testFiveScriptNodesAreRejectedIncludingDisabledNodes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = AudioDSPController(store: DSPPresetStore(rootURL: root))
        var candidate = AudioDSPConfiguration.defaultFlat
        candidate.nodes.append(contentsOf: (0..<5).map { _ in .script(enabled: false) })

        do {
            _ = try owner.validate(candidate)
            XCTFail("The chain must be limited to four script nodes.")
        } catch let error as DSPConfigurationValidationError {
            XCTAssertTrue(error.diagnostics.contains { $0.fieldPath == "nodes" })
        }
    }

    func testConfigurationValidationDefersFormatDependentChecksUntilSourceIsKnown() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = AudioDSPController(store: DSPPresetStore(rootURL: root))
        await owner.ensureLoaded()
        var candidate = AudioDSPConfiguration.defaultFlat
        var node = DSPNodeConfiguration.script()
        var script = try XCTUnwrap(node.scriptParameters)
        script.source = "process { output = inputAt(2); }"
        node.scriptParameters = script
        candidate.nodes.append(node)

        XCTAssertNoThrow(try owner.validate(candidate))
    }

    func testApplyRequiresSuccessfulCompileForCurrentDraftRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = AudioDSPController(store: DSPPresetStore(rootURL: root.appendingPathComponent("Presets")))
        await owner.ensureLoaded()
        let nodeID = UUID()
        var candidate = owner.configuration
        candidate.nodes.append(.script(nodeID: nodeID))
        _ = try owner.apply(candidate)
        owner.commitPendingApply()
        let originalRevision = owner.revisionString
        let scriptController = DSPScriptController(
            draftStore: DSPScriptDraftStore(rootURL: root.appendingPathComponent("Drafts"))
        )
        scriptController.bind(dspController: owner)
        let draft = try await scriptController.updateDraft(
            nodeID: nodeID,
            languageVersion: 1,
            source: DSPScriptNodeParameters.defaultSource,
            values: [:]
        )

        do {
            _ = try scriptController.applyCompiledDraft(
                nodeID: nodeID,
                expectedDraftRevision: draft.revisionString
            )
            XCTFail("An uncompiled draft must not be applied.")
        } catch is DSPScriptControllerError {
            XCTAssertEqual(owner.revisionString, originalRevision)
        }

        let compiled = try await scriptController.compileDraft(
            nodeID: nodeID,
            format: stereoFormat,
            expectedDraftRevision: draft.revisionString
        )
        let status = try scriptController.applyCompiledDraft(
            nodeID: nodeID,
            expectedDraftRevision: compiled.draftRevision,
            expectedConfigurationRevision: originalRevision
        )
        XCTAssertEqual(status.revisionString, owner.revisionString)
        XCTAssertEqual(owner.configuration.nodes.first(where: { $0.nodeID == nodeID })?.scriptParameters?.source,
                       DSPScriptNodeParameters.defaultSource)
    }

    private var stereoFormat: DSPAudioFormat {
        DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDSPScriptControllerTests-\(UUID().uuidString)", isDirectory: true)
    }
}
