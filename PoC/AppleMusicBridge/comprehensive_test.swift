import Foundation

// MARK: - Test Configuration
struct TestConfig {
    static let pollInterval: TimeInterval = 0.5
    static let testDuration: TimeInterval = 30.0
    static let dragTestDuration: TimeInterval = 20.0
}

// MARK: - Logger
class TestLogger {
    static let shared = TestLogger()
    private let dateFormatter: DateFormatter
    private var logs: [(timestamp: Date, type: String, message: String)] = []

    init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ type: String, _ message: String) {
        let timestamp = Date()
        logs.append((timestamp, type, message))
        let timeStr = dateFormatter.string(from: timestamp)
        print("[\(timeStr)] [\(type)] \(message)")
    }

    func info(_ message: String) { log("INFO", message) }
    func warn(_ message: String) { log("WARN", message) }
    func error(_ message: String) { log("ERROR", message) }
    func data(_ message: String) { log("DATA", message) }
    func result(_ message: String) { log("RESULT", message) }

    func exportReport() -> String {
        var report = "=== Test Report ===\n\n"
        for log in logs {
            let timeStr = dateFormatter.string(from: log.timestamp)
            report += "[\(timeStr)] [\(log.type)] \(log.message)\n"
        }
        return report
    }
}

// MARK: - AppleScript Executor
class AppleScriptExecutor {
    static let shared = AppleScriptExecutor()

    private var processStats = ProcessStats()
    private let statsQueue = DispatchQueue(label: "stats")

    struct ProcessStats {
        var callCount: Int = 0
        var totalExecutionTime: TimeInterval = 0
        var minExecutionTime: TimeInterval = .infinity
        var maxExecutionTime: TimeInterval = 0
        var totalCPUTime: TimeInterval = 0
        var totalMemoryUsage: UInt64 = 0
        var errorCount: Int = 0

        var averageExecutionTime: TimeInterval {
            callCount > 0 ? totalExecutionTime / Double(callCount) : 0
        }
    }

    func execute(_ source: String) -> String {
        let startTime = Date()
        let startCPUTime = getCurrentThreadCPUTime()

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        var result = ""
        do {
            try task.run()
            task.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                result = "ERROR:\(errorStr)"
                statsQueue.async { self.processStats.errorCount += 1 }
            }
        } catch {
            result = "ERROR:\(error)"
            statsQueue.async { self.processStats.errorCount += 1 }
        }

        // Record stats
        let executionTime = Date().timeIntervalSince(startTime)
        let cpuTime = getCurrentThreadCPUTime() - startCPUTime

        statsQueue.async {
            self.processStats.callCount += 1
            self.processStats.totalExecutionTime += executionTime
            self.processStats.totalCPUTime += cpuTime
            self.processStats.minExecutionTime = min(self.processStats.minExecutionTime, executionTime)
            self.processStats.maxExecutionTime = max(self.processStats.maxExecutionTime, executionTime)
        }

        return result
    }

    func getStats() -> ProcessStats {
        return statsQueue.sync { processStats }
    }

    func resetStats() {
        statsQueue.sync {
            processStats = ProcessStats()
        }
    }

    private func getCurrentThreadCPUTime() -> TimeInterval {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return 0
        }

        return TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1_000_000
    }
}

// MARK: - Position Monitor
class PositionMonitor {
    private var timer: Timer?
    private var isRunning = false
    private var positionHistory: [(timestamp: Date, position: Double)] = []
    private let historyQueue = DispatchQueue(label: "history")

    struct PositionChange {
        let from: Double
        let to: Double
        let delta: Double
        let timeInterval: TimeInterval
        let isJump: Bool
        let isBackwards: Bool
    }

    func start(interval: TimeInterval = TestConfig.pollInterval, callback: @escaping (Double, PositionChange?) -> Void) {
        guard !isRunning else { return }
        isRunning = true

        var lastPosition: Double = -1
        var lastTime: Date?

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            let script = """
            tell application "Music"
                try
                    return player position
                on error
                    return "ERROR"
                end try
            end tell
            """
            let result = AppleScriptExecutor.shared.execute(script)
            let position = Double(result) ?? -1

            let now = Date()
            var change: PositionChange?

            if lastPosition >= 0 && position >= 0 {
                let delta = position - lastPosition
                let timeDiff = lastTime.map { now.timeIntervalSince($0) } ?? interval

                // Detect jumps (position change > 2 seconds in one poll, or backwards)
                let isJump = abs(delta) > 2.0
                let isBackwards = delta < -0.5

                change = PositionChange(
                    from: lastPosition,
                    to: position,
                    delta: delta,
                    timeInterval: timeDiff,
                    isJump: isJump,
                    isBackwards: isBackwards
                )
            }

            self.historyQueue.async {
                self.positionHistory.append((now, position))
            }

            lastPosition = position
            lastTime = now
            callback(position, change)
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func getHistory() -> [(timestamp: Date, position: Double)] {
        return historyQueue.sync { positionHistory }
    }

    func clearHistory() {
        historyQueue.async { self.positionHistory.removeAll() }
    }
}

// MARK: - State Monitor
class StateMonitor {
    private var lastState: String?
    private var stateHistory: [(timestamp: Date, from: String, to: String)] = []

    func checkStateChange() -> (changed: Bool, from: String?, to: String) {
        let script = """
        tell application "Music"
            try
                return player state as string
            on error
                return "error"
            end try
        end tell
        """
        let result = AppleScriptExecutor.shared.execute(script)
        let currentState = result.isEmpty ? "unknown" : result

        if lastState != currentState {
            let from = lastState
            lastState = currentState
            if let from = from {
                stateHistory.append((Date(), from, currentState))
            }
            return (true, from, currentState)
        }
        return (false, nil, currentState)
    }

    func getHistory() -> [(timestamp: Date, from: String, to: String)] {
        return stateHistory
    }

    func reset() {
        lastState = nil
        stateHistory.removeAll()
    }
}

// MARK: - Tests

/// Test 1: Position Sync Test (Drag Seek Test)
func runPositionSyncTest() {
    TestLogger.shared.info("=".repeated(60))
    TestLogger.shared.info("TEST 1: Position Sync Test (拖动进度测试)")
    TestLogger.shared.info("=".repeated(60))
    TestLogger.shared.info("Instructions:")
    TestLogger.shared.info("  1. Music.app 正在播放时")
    TestLogger.shared.info("  2. 手动拖动进度条到任意位置")
    TestLogger.shared.info("  3. 观察输出是否有延迟或乱跳")
    TestLogger.shared.info("")
    TestLogger.shared.info("Starting in 3 seconds...")

    Thread.sleep(forTimeInterval: 3)

    let monitor = PositionMonitor()
    var jumpCount = 0
    var backwardsCount = 0
    var syncDelays: [TimeInterval] = []

    let semaphore = DispatchSemaphore(value: 0)
    var lastJumpTime: Date?

    monitor.start(interval: 0.3) { position, change in
        guard let change = change else { return }

        if change.isJump {
            jumpCount += 1
            let timeSinceLastJump = lastJumpTime.map { Date().timeIntervalSince($0) } ?? 0
            lastJumpTime = Date()

            TestLogger.shared.warn("🔄 POSITION JUMP DETECTED")
            TestLogger.shared.warn("   From: \(String(format: "%.2f", change.from))s")
            TestLogger.shared.warn("   To:   \(String(format: "%.2f", change.to))s")
            TestLogger.shared.warn("   Delta: \(String(format: "%.2f", change.delta))s")
            TestLogger.shared.warn("   Time since last jump: \(String(format: "%.2f", timeSinceLastJump))s")

            syncDelays.append(timeSinceLastJump)
        }

        if change.isBackwards {
            backwardsCount += 1
            TestLogger.shared.data("⏪ BACKWARDS SEEK: \(String(format: "%.2f", change.from)) → \(String(format: "%.2f", change.to))")
        }
    }

    TestLogger.shared.info("Monitoring position for \(Int(TestConfig.dragTestDuration))s...")
    TestLogger.shared.info("Please drag the progress bar in Music.app now!")
    TestLogger.shared.info("")

    Thread.sleep(forTimeInterval: TestConfig.dragTestDuration)
    monitor.stop()

    TestLogger.shared.info("")
    TestLogger.shared.result("=".repeated(60))
    TestLogger.shared.result("Position Sync Test Results")
    TestLogger.shared.result("=".repeated(60))
    TestLogger.shared.result("Total jumps detected: \(jumpCount)")
    TestLogger.shared.result("Backwards seeks: \(backwardsCount)")
    if !syncDelays.isEmpty {
        let avgDelay = syncDelays.reduce(0, +) / Double(syncDelays.count)
        TestLogger.shared.result("Average sync delay: \(String(format: "%.2f", avgDelay))s")
    }
    TestLogger.shared.result("")
    TestLogger.shared.result(jumpCount > 0 ? "⚠️  Jumps detected - check if they match your drags" : "✅ No unexpected jumps")
}

/// Test 2: State Transition Test
func runStateTransitionTest() {
    TestLogger.shared.info("")
    TestLogger.shared.info("=".repeated(60))
    TestLogger.shared.info("TEST 2: State Transition Test (状态切换测试)")
    TestLogger.shared.info("=".repeated(60))

    let monitor = StateMonitor()
    var transitions: [(action: String, from: String, to: String, time: TimeInterval)] = []

    func executeAndWait(_ script: String, description: String, expectedDelay: TimeInterval = 0.5) {
        let startTime = Date()
        TestLogger.shared.info("Action: \(description)...")

        let _ = AppleScriptExecutor.shared.execute(script)

        // Wait for state to settle
        var settled = false
        var lastCheckTime = Date()

        while !settled && Date().timeIntervalSince(startTime) < 3.0 {
            let (changed, from, to) = monitor.checkStateChange()
            if changed, let from = from {
                let elapsed = Date().timeIntervalSince(startTime)
                transitions.append((description, from, to, elapsed))
                TestLogger.shared.data("  State changed: \(from) → \(to) (\(String(format: "%.2f", elapsed))s)")
                settled = true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if !settled {
            TestLogger.shared.warn("  No state change detected")
        }

        Thread.sleep(forTimeInterval: expectedDelay)
    }

    // Test sequence
    let tests = [
        ("tell application \"Music\" to pause", "Pause"),
        ("tell application \"Music\" to play", "Play/Resume"),
        ("tell application \"Music\" to playpause", "Toggle (Play/Pause)"),
        ("tell application \"Music\" to playpause", "Toggle (Pause/Play)"),
        ("tell application \"Music\" to next track", "Next Track"),
        ("tell application \"Music\" to previous track", "Previous Track"),
    ]

    for (script, desc) in tests {
        executeAndWait(script, description: desc, expectedDelay: 1.0)
    }

    TestLogger.shared.info("")
    TestLogger.shared.result("=".repeated(60))
    TestLogger.shared.result("State Transition Results")
    TestLogger.shared.result("=".repeated(60))

    if transitions.isEmpty {
        TestLogger.shared.result("⚠️  No state transitions detected")
    } else {
        for t in transitions {
            TestLogger.shared.result("\(t.action): \(t.from) → \(t.to) in \(String(format: "%.2f", t.time))s")
        }

        let avgTime = transitions.map { $0.time }.reduce(0, +) / Double(transitions.count)
        TestLogger.shared.result("")
        TestLogger.shared.result("Average transition time: \(String(format: "%.2f", avgTime))s")
    }

    // Check for state accuracy
    TestLogger.shared.result("")
    TestLogger.shared.result("State Accuracy: \(transitions.count == tests.count ? "✅ PASS" : "⚠️  PARTIAL")")
}

/// Test 3: Resource Usage Test
func runResourceUsageTest() {
    TestLogger.shared.info("")
    TestLogger.shared.info("=".repeated(60))
    TestLogger.shared.info("TEST 3: Resource Usage Test (资源占用测试)")
    TestLogger.shared.info("=".repeated(60))

    let executor = AppleScriptExecutor.shared
    executor.resetStats()

    let pollCount = 60 // 30 seconds at 0.5s interval
    let interval: TimeInterval = 0.5

    TestLogger.shared.info("Configuration:")
    TestLogger.shared.info("  Poll interval: \(interval)s")
    TestLogger.shared.info("  Total polls: \(pollCount)")
    TestLogger.shared.info("  Test duration: \(Double(pollCount) * interval)s")
    TestLogger.shared.info("")
    TestLogger.shared.info("Running resource test...")

    // Get baseline
    let baselineMemory = getMemoryUsage()
    let startTime = Date()

    for i in 0..<pollCount {
        let script = """
        tell application "Music"
            try
                set currentTrack to current track
                set trackName to name of currentTrack
                set trackArtist to artist of currentTrack
                set trackDuration to duration of currentTrack
                set trackPosition to player position
                set trackState to player state as string
                return trackName & "|" & trackArtist & "|" & trackDuration & "|" & trackPosition & "|" & trackState
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """

        let _ = executor.execute(script)

        if i % 10 == 0 {
            TestLogger.shared.data("  Poll \(i)/\(pollCount) completed")
        }

        // Sleep until next poll
        let elapsed = Date().timeIntervalSince(startTime)
        let nextPollTime = Double(i + 1) * interval
        let sleepTime = nextPollTime - elapsed
        if sleepTime > 0 {
            Thread.sleep(forTimeInterval: sleepTime)
        }
    }

    let totalTime = Date().timeIntervalSince(startTime)
    let stats = executor.getStats()
    let finalMemory = getMemoryUsage()

    TestLogger.shared.info("")
    TestLogger.shared.result("=".repeated(60))
    TestLogger.shared.result("Resource Usage Results")
    TestLogger.shared.result("=".repeated(60))
    TestLogger.shared.result("Total calls: \(stats.callCount)")
    TestLogger.shared.result("Total time: \(String(format: "%.2f", totalTime))s")
    TestLogger.shared.result("")
    TestLogger.shared.result("Execution Time:")
    TestLogger.shared.result("  Min: \(String(format: "%.3f", stats.minExecutionTime * 1000))ms")
    TestLogger.shared.result("  Max: \(String(format: "%.3f", stats.maxExecutionTime * 1000))ms")
    TestLogger.shared.result("  Avg: \(String(format: "%.3f", stats.averageExecutionTime * 1000))ms")
    TestLogger.shared.result("  Total: \(String(format: "%.2f", stats.totalExecutionTime * 1000))ms")
    TestLogger.shared.result("")
    TestLogger.shared.result("Throughput:")
    TestLogger.shared.result("  Calls per second: \(String(format: "%.2f", Double(stats.callCount) / totalTime))")
    TestLogger.shared.result("  Time per call: \(String(format: "%.3f", stats.totalExecutionTime / Double(stats.callCount) * 1000))ms")
    TestLogger.shared.result("")
    TestLogger.shared.result("Errors: \(stats.errorCount)")
    TestLogger.shared.result("")

    // Estimate impact
    let callsPerMinute = 120 // 0.5s interval
    let dailyCalls = callsPerMinute * 60 * 24 // 24 hours
    let dailyTimeSeconds = Double(dailyCalls) * stats.averageExecutionTime

    TestLogger.shared.result("Projected Impact (0.5s polling, 24h):")
    TestLogger.shared.result("  Daily calls: \(dailyCalls)")
    TestLogger.shared.result("  Daily execution time: \(String(format: "%.1f", dailyTimeSeconds))s (\(String(format: "%.2f", dailyTimeSeconds / 60))min)")
    TestLogger.shared.result("  CPU overhead estimate: \(String(format: "%.3f", (dailyTimeSeconds / (24 * 3600)) * 100))%")

    let assessment = stats.averageExecutionTime < 0.1 ? "✅ ACCEPTABLE" : "⚠️  HIGH"
    TestLogger.shared.result("")
    TestLogger.shared.result("Resource Usage Assessment: \(assessment)")
}

// MARK: - Helpers
func getMemoryUsage() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_,
                     task_flavor_t(MACH_TASK_BASIC_INFO),
                     $0,
                     &count)
        }
    }

    guard kerr == KERN_SUCCESS else {
        return 0
    }

    return info.resident_size
}

extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}

// MARK: - Main
print("""
╔════════════════════════════════════════════════════════════════╗
║     AppleMusicBridge - 综合压力测试                            ║
║                                                                ║
║  测试项目:                                                     ║
║    1. 拖动进度同步测试 (Position Sync Test)                    ║
║    2. 状态切换测试 (State Transition Test)                     ║
║    3. 资源占用测试 (Resource Usage Test)                       ║
╚════════════════════════════════════════════════════════════════╝
""")

// Check Music.app
TestLogger.shared.info("Checking Music.app...")
let checkScript = """
tell application "System Events"
    return (name of processes) contains "Music"
end tell
"""
let isRunning = AppleScriptExecutor.shared.execute(checkScript).lowercased() == "true"

if !isRunning {
    TestLogger.shared.error("Music.app is not running. Please start it and play a song.")
    exit(1)
}

TestLogger.shared.info("✅ Music.app is running\n")

// Run all tests
runPositionSyncTest()
runStateTransitionTest()
runResourceUsageTest()

// Final summary
TestLogger.shared.info("")
TestLogger.shared.info("=".repeated(60))
TestLogger.shared.info("ALL TESTS COMPLETE")
TestLogger.shared.info("=".repeated(60))

print("")
print(TestLogger.shared.exportReport())
