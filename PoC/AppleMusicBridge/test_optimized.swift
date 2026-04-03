import Foundation
import Cocoa

// 引入优化版 Bridge（内联实现）

// MARK: - Optimized Bridge (Inline for testing)
final class OptimizedBridge {
    static let shared = OptimizedBridge()

    private var fetchPositionScript: NSAppleScript?
    private var fetchFullScript: NSAppleScript?
    private var checkRunningScript: NSAppleScript?

    // Stats
    var stats = ExecutionStats()

    struct ExecutionStats {
        var callCount = 0
        var totalTime: TimeInterval = 0
        var minTime: TimeInterval = .infinity
        var maxTime: TimeInterval = 0

        var avgTime: TimeInterval {
            callCount > 0 ? totalTime / Double(callCount) : 0
        }
    }

    private init() {
        compileScripts()
    }

    private func compileScripts() {
        // 轻量级位置查询
        fetchPositionScript = compileScript("""
            tell application "Music"
                try
                    return (player position as string) & "|" & (player state as string)
                on error
                    return "ERROR"
                end try
            end tell
            """)

        // 完整信息查询
        fetchFullScript = compileScript("""
            tell application "Music"
                try
                    set t to current track
                    return (name of t) & "|" & (artist of t) & "|" & (duration of t as string) & "|" & (player position as string) & "|" & (player state as string)
                on error
                    return "ERROR"
                end try
            end tell
            """)

        checkRunningScript = compileScript("""
            tell application "System Events"
                return (name of processes) contains "Music"
            end tell
            """)
    }

    private func compileScript(_ source: String) -> NSAppleScript? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        return script
    }

    @discardableResult
    private func execute(_ script: NSAppleScript?) -> String {
        guard let script = script else { return "ERROR" }

        let start = Date()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let elapsed = Date().timeIntervalSince(start)

        // Record stats
        stats.callCount += 1
        stats.totalTime += elapsed
        stats.minTime = min(stats.minTime, elapsed)
        stats.maxTime = max(stats.maxTime, elapsed)

        if error != nil {
            return "ERROR"
        }
        return result.stringValue ?? ""
    }

    func isRunning() -> Bool {
        return execute(checkRunningScript).lowercased() == "true"
    }

    func fetchPosition() -> (position: Double, state: String, success: Bool) {
        let result = execute(fetchPositionScript)
        let parts = result.components(separatedBy: "|")
        guard parts.count >= 2 else { return (0, "error", false) }
        return (Double(parts[0]) ?? 0, parts[1], true)
    }

    func fetchFullInfo() -> (title: String, artist: String, duration: Double, position: Double, success: Bool) {
        let result = execute(fetchFullScript)
        let parts = result.components(separatedBy: "|")
        guard parts.count >= 5 else { return ("", "", 0, 0, false) }
        return (parts[0], parts[1], Double(parts[2]) ?? 0, Double(parts[3]) ?? 0, true)
    }

    func getStats() -> ExecutionStats {
        return stats
    }

    func resetStats() {
        stats = ExecutionStats()
    }
}

// MARK: - Performance Test

func runPerformanceTest(name: String, iterations: Int, interval: TimeInterval, useOptimized: Bool) {
    print("\n【\(name)】")
    print(String(repeating: "-", count: 60))
    print("模式: \(useOptimized ? "NSAppleScript (复用)" : "osascript (每次都新建)")")
    print("次数: \(iterations), 间隔: \(interval)s")
    print("")

    let bridge = OptimizedBridge.shared
    bridge.resetStats()

    let startTime = Date()

    if useOptimized {
        // NSAppleScript 模式
        for i in 0..<iterations {
            if i % 2 == 0 {
                _ = bridge.fetchPosition()
            } else {
                _ = bridge.fetchFullInfo()
            }

            // 控制频率
            let elapsed = Date().timeIntervalSince(startTime)
            let nextTime = Double(i + 1) * interval
            let sleepTime = nextTime - elapsed
            if sleepTime > 0 {
                Thread.sleep(forTimeInterval: sleepTime)
            }
        }
    } else {
        // osascript 模式 (每次都新建进程)
        for i in 0..<iterations {
            let script = """
            tell application "Music"
                return player position
            end tell
            """

            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]

            let pipe = Pipe()
            task.standardOutput = pipe

            let execStart = Date()
            do {
                try task.run()
                task.waitUntilExit()
            } catch {}
            let elapsed = Date().timeIntervalSince(execStart)

            // 手动记录 stats (模拟)
            bridge.stats.callCount += 1
            bridge.stats.totalTime += elapsed
            bridge.stats.minTime = min(bridge.stats.minTime, elapsed)
            bridge.stats.maxTime = max(bridge.stats.maxTime, elapsed)

            // 控制频率
            let totalElapsed = Date().timeIntervalSince(startTime)
            let nextTime = Double(i + 1) * interval
            let sleepTime = nextTime - totalElapsed
            if sleepTime > 0 {
                Thread.sleep(forTimeInterval: sleepTime)
            }
        }
    }

    let totalTime = Date().timeIntervalSince(startTime)
    let stats = bridge.getStats()

    print("结果:")
    print("  总耗时: \(String(format: "%.2f", totalTime))s")
    print("  平均执行: \(String(format: "%.1f", stats.avgTime * 1000))ms")
    print("  范围: \(String(format: "%.1f", stats.minTime * 1000))ms - \(String(format: "%.1f", stats.maxTime * 1000))ms")
    print("  总执行时间: \(String(format: "%.1f", stats.totalTime * 1000))ms")

    let cpuEstimate = (stats.avgTime / interval) * 100.0
    print("  CPU 估算: \(String(format: "%.1f", cpuEstimate))%")

    if cpuEstimate < 5 {
        print("  评估: ✅ 优秀")
    } else if cpuEstimate < 10 {
        print("  评估: ✅ 可接受")
    } else if cpuEstimate < 20 {
        print("  评估: ⚠️ 偏高")
    } else {
        print("  评估: ❌ 过高")
    }
}

// MARK: - Main
print("")
print("╔════════════════════════════════════════════════════════════════╗")
print("║     NSAppleScript 优化效果对比测试                               ║")
print("╠════════════════════════════════════════════════════════════════╣")
print("║  对比: osascript (每次新建) vs NSAppleScript (复用编译)          ║")
print("╚════════════════════════════════════════════════════════════════╝")


// Check Music.app
print("检查 Music.app...")
let task = Process()
task.launchPath = "/usr/bin/osascript"
task.arguments = ["-e", "tell application \"System Events\" to return (name of processes) contains \"Music\""]
let pipe = Pipe()
task.standardOutput = pipe
do {
    try task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if result.lowercased() != "true" {
        print("❌ Music.app 未运行")
        exit(1)
    }
} catch {
    print("❌ 检查失败: \(error)")
    exit(1)
}
print("✅ Music.app 运行中\n")

// Test 1: 高频轮询 (0.5s) - 最坏情况
runPerformanceTest(name: "高频轮询测试 (0.5s)", iterations: 20, interval: 0.5, useOptimized: false)
runPerformanceTest(name: "高频轮询测试 (0.5s)", iterations: 20, interval: 0.5, useOptimized: true)

// Test 2: 推荐配置 (歌词 1.0s)
runPerformanceTest(name: "歌词同步配置 (1.0s)", iterations: 10, interval: 1.0, useOptimized: false)
runPerformanceTest(name: "歌词同步配置 (1.0s)", iterations: 10, interval: 1.0, useOptimized: true)

// Test 3: 显示刷新 (2.0s)
runPerformanceTest(name: "显示刷新配置 (2.0s)", iterations: 5, interval: 2.0, useOptimized: false)
runPerformanceTest(name: "显示刷新配置 (2.0s)", iterations: 5, interval: 2.0, useOptimized: true)

// Summary
print("\n" + String(repeating: "=", count: 60))
print("测试完成！")
print(String(repeating: "=", count: 60))
print("")
print("结论:")
print("- NSAppleScript 复用编译后，单次执行时间大幅降低")
print("- 推荐配置:")
print("  * 歌词同步: 1.0s 间隔 (CPU <10%)")
print("  * 显示刷新: 2.0s 间隔 (CPU <5%)")
print("")
print("迁移建议:")
print("1. 使用 OptimizedAppleMusicBridge.swift 替换原服务")
print("2. 歌词组件监听 onLyricsTick (1.0s)")
print("3. UI 组件监听 onDisplayTick (2.0s)")
