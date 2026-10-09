import XCTest
@testable import kmgccc_player

final class AudioDSPScriptTests: XCTestCase {
    func testGainScriptCompilesToFormatBoundProgramAndReflectsParameter() throws {
        let program = try compile("""
        param gainDB(-24, 12)=0;
        prepare {
            let gain = dbToGain(gainDB);
        }
        process {
            output = input * gain;
        }
        """)

        XCTAssertEqual(program.languageVersion, 1)
        XCTAssertEqual(program.parameters.map(\.name), ["gainDB"])
        XCTAssertEqual(program.parameterValues["gainDB"], 0.0)
        XCTAssertEqual(program.format.channelCount, 1)
        XCTAssertEqual(program.latencyFrames, 0)
        // input 读取 + gain 常量 + 乘法 + output 写入；emit 对常量也保底计 1。
        XCTAssertEqual(program.weightedOperationsPerFrame, 4)
        XCTAssertFalse(program.sourceHash.isEmpty)
    }

    func testExecutedConstantInstructionsCountTowardOperationBudget() {
        var lines = ["process {"]
        for index in 0..<510 {
            lines.append("let constant\(index) = \(index);")
        }
        lines.append("output = input;")
        lines.append("}")

        XCTAssertThrowsError(try compile(lines.joined(separator: "\n"))) { error in
            let compilationError = error as? DSPScriptCompilationError
            XCTAssertTrue(compilationError?.diagnostics.contains {
                $0.code == "script.operationBudgetExceeded"
            } == true)
        }
    }

    func testTernaryDoesNotRunUnselectedDivisionOrStatefulBranch() throws {
        let division = try compile("""
        process {
            output = input == 0 ? 0 : 1 / input;
        }
        """)
        var divisionRuntime = DSPScriptRuntime(program: division, channelMask: [true])
        var silence = [0.0]
        divisionRuntime.processFrame(&silence)
        XCTAssertEqual(silence[0], 0)
        XCTAssertFalse(divisionRuntime.isFaulted)
        var tone = [1.0]
        divisionRuntime.processFrame(&tone)
        XCTAssertEqual(tone[0], 1)
        XCTAssertFalse(divisionRuntime.isFaulted)

        let stateful = try compile("""
        process {
            output = input == 0 ? 0 : smooth(input + 1, 0.5);
        }
        """)
        var statefulRuntime = DSPScriptRuntime(program: stateful, channelMask: [true])
        var quiet = [0.0]
        statefulRuntime.processFrame(&quiet)
        var firstSignal = [1.0]
        statefulRuntime.processFrame(&firstSignal)
        XCTAssertEqual(firstSignal[0], 1, accuracy: 1e-12)
        XCTAssertFalse(statefulRuntime.isFaulted)
    }

    func testSmoothStateIsIndependentPerChannelAndSurvivesCopies() throws {
        let program = try compile("""
        process {
            output = smooth(input, 0.5);
        }
        """, channels: 2)
        var runtime = DSPScriptRuntime(program: program, channelMask: [true, true])
        var frame = [1.0, 10.0]
        runtime.processFrame(&frame)
        XCTAssertEqual(frame, [0.5, 5])

        var copied = runtime.makeFreshState()
        copied.copyState(from: runtime)
        var left = [0.0, 0.0]
        var right = [0.0, 0.0]
        runtime.processFrame(&left)
        copied.processFrame(&right)
        XCTAssertEqual(left, [0.25, 2.5])
        XCTAssertEqual(right, left)
    }

    func testDeclaredLatencyDoesNotDoubleDelayWetAndAlignsUnselectedDry() throws {
        let program = try compile("""
        latency 3;
        process {
            output = input;
        }
        """, channels: 2)
        var runtime = DSPScriptRuntime(program: program, channelMask: [true, false])
        var actual = [[Double]]()
        for value in 1...5 {
            var frame = [Double(value), Double(value * 10)]
            runtime.processFrame(&frame)
            actual.append(frame)
        }
        XCTAssertEqual(actual, [
            [1, 0], [2, 0], [3, 0], [4, 10], [5, 20]
        ])
    }

    func testBoundedPreviewCopyMatchesFullStateCopyForDelayAndLatencyRings() throws {
        let program = try compile("""
        latency 2;
        process {
            output = delay(input, 8);
        }
        """)
        var original = DSPScriptRuntime(program: program, channelMask: [true, false])
        for value in 0..<11 {
            var frame = [Double(value), Double(value * 10)]
            original.processFrame(&frame)
        }
        var boundedCopy = original.makeFreshState()

        // Reuse the same partial-copy destination across successive one-frame
        // preview windows. Both cursors cross ring wraparound while cells
        // outside each bounded window remain intentionally stale.
        for value in 11..<20 {
            var fullCopy = original.makeFreshState()
            fullCopy.copyState(from: original)
            boundedCopy.copyState(from: original, previewFrames: 1)

            var sourceFrame = [Double(value), Double(value * 10)]
            var fullFrame = sourceFrame
            var boundedFrame = sourceFrame
            original.processFrame(&sourceFrame)
            fullCopy.processFrame(&fullFrame)
            boundedCopy.processFrame(&boundedFrame)
            XCTAssertEqual(fullFrame, sourceFrame)
            XCTAssertEqual(boundedFrame, sourceFrame)
        }
    }

    func testFloat32OverflowFaultsAndReturnsFiniteAlignedDryOutput() throws {
        let program = try compile("""
        param multiplier(1, 1e300)=1e300;
        process {
            output = input * multiplier;
        }
        """)
        var runtime = DSPScriptRuntime(program: program, channelMask: [true])
        var frame = [0.5]
        runtime.processFrame(&frame)
        XCTAssertTrue(runtime.isFaulted)
        XCTAssertEqual(runtime.diagnostic?.code, "dsp.script.outputNotRepresentable")
        XCTAssertTrue(frame[0].isFinite)
        for _ in 0..<70 {
            var tail = [0.25]
            runtime.processFrame(&tail)
            XCTAssertTrue(tail[0].isFinite)
            frame = tail
        }
        XCTAssertEqual(frame[0], 0.25, accuracy: 1e-12)
    }

    func testFormatIndependentValidationAcceptsDeferredMultichannelAndSampleRateUse() throws {
        let parameters = try DSPScriptCompiler.validateSource(source: """
        prepare {
            let rateScale = sampleRate / 48000;
        }
        process {
            output = inputAt(2) * rateScale;
        }
        """)
        XCTAssertTrue(parameters.isEmpty)
    }

    func testFormatBoundCompileRejectsInputChannelOutsideActualFormat() {
        XCTAssertThrowsError(try compile("""
        process {
            output = inputAt(2);
        }
        """)) { error in
            let diagnostics = (error as? DSPScriptCompilationError)?.diagnostics ?? []
            XCTAssertEqual(diagnostics.first?.code, "script.invalidInputChannel")
        }
    }

    func testCompilerReportsSourceLocationForUnknownNameAndRejectsLoopSyntax() {
        XCTAssertThrowsError(try compile("""
        process {
            output = input * missing;
        }
        """)) { error in
            let diagnostic = (error as? DSPScriptCompilationError)?.diagnostics.first
            XCTAssertEqual(diagnostic?.code, "script.unknownName")
            XCTAssertEqual(diagnostic?.line, 2)
            XCTAssertNotNil(diagnostic?.column)
        }
        XCTAssertThrowsError(try compile("""
        process {
            while (1) { output = input; }
        }
        """))
    }

    func testBothLeftAndRightAssociativeExpressionsStayWithinTheDepthBudget() {
        let addition = Array(repeating: "input", count: 100).joined(separator: " + ")
        let exponentiation = Array(repeating: "input", count: 100).joined(separator: " ^ ")
        XCTAssertThrowsError(try compile("process { output = \(addition); }"))
        XCTAssertThrowsError(try compile("process { output = \(exponentiation); }"))
    }

    func testFixtureRunnerReportsDeclaredAndObservedImpulseTiming() async throws {
        let program = try compile("""
        latency 4;
        process {
            output = delay(input, 4);
        }
        """)
        let results = try await DSPScriptFixtureRunner.run(
            program: program,
            channelMask: [true],
            fixtures: [.impulse(durationSeconds: 0.01, amplitude: 0.5)]
        )
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.scriptFaulted)
        XCTAssertEqual(result.expectedLatencyFrames, 4)
        XCTAssertEqual(result.measuredImpulsePeakFrame, 4)
        XCTAssertTrue(result.inputRMS.isFinite)
        XCTAssertTrue(result.outputRMS.isFinite)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testResetReplaysDelayStateDeterministically() throws {
        let program = try compile("""
        process {
            output = delay(input, 4);
        }
        """)
        var runtime = DSPScriptRuntime(program: program, channelMask: [true])
        var firstRun = [Double]()
        for value in 1...8 {
            var frame = [Double(value)]
            runtime.processFrame(&frame)
            firstRun.append(frame[0])
        }
        runtime.reset()
        var secondRun = [Double]()
        for value in 1...8 {
            var frame = [Double(value)]
            runtime.processFrame(&frame)
            secondRun.append(frame[0])
        }
        XCTAssertEqual(firstRun, secondRun)
        XCTAssertEqual(Array(firstRun.prefix(4)), [0, 0, 0, 0])
    }

    private func compile(_ source: String, channels: Int = 1) throws -> DSPScriptProgram {
        try DSPScriptCompiler.compile(
            source: source,
            format: DSPAudioFormat(
                sampleRate: 48_000,
                channelCount: channels,
                rawLayoutData: nil,
                channelLabels: nil,
                layoutIsKnown: false
            )
        )
    }
}
