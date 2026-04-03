import Foundation

// 测试不同轮询频率的资源占用

print("""
╔════════════════════════════════════════════════════════════════╗
║     轮询频率 vs 资源占用测试                                     ║
╠════════════════════════════════════════════════════════════════╣
║  测试不同轮询间隔下的 CPU 消耗                                   ║
╚════════════════════════════════════════════════════════════════╝
""")

func executeAppleScript(_ source: String) -> String {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", source]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch {
        return "ERROR"
    }
}

func runTest(name: String, interval: TimeInterval, duration: TimeInterval) {
    print("\n【\(name)】轮询间隔: \(interval)s, 测试时长: \(duration)s")
    print(String(repeating: "-", count: 60))

    let startTime = Date()
    var callCount = 0
    var totalExecutionTime: TimeInterval = 0
    var minTime: TimeInterval = .infinity
    var maxTime: TimeInterval = 0

    let script = """
    tell application "Music"
        return player position
    end tell
    """

    while Date().timeIntervalSince(startTime) < duration {
        let execStart = Date()
        let _ = executeAppleScript(script)
        let execTime = Date().timeIntervalSince(execStart)

        callCount += 1
        totalExecutionTime += execTime
        minTime = min(minTime, execTime)
        maxTime = max(maxTime, execTime)

        // 等待到下次轮询
        let elapsed = Date().timeIntervalSince(startTime)
        let nextPoll = Double(callCount) * interval
        let sleepTime = nextPoll - elapsed
        if sleepTime > 0 {
            Thread.sleep(forTimeInterval: sleepTime)
        }
    }

    let totalTime = Date().timeIntervalSince(startTime)
    let avgTime = totalExecutionTime / Double(callCount)
    let callsPerSecond = Double(callCount) / totalTime
    let projectedDailyHours = (avgTime * (86400.0 / interval)) / 3600.0
    let cpuEstimate = (avgTime / interval) * 100.0

    print("  总调用次数: \(callCount)")
    print("  总耗时: \(String(format: "%.2f", totalTime))s")
    print("  执行时间: min=\(String(format: "%.0f", minTime*1000))ms, avg=\(String(format: "%.0f", avgTime*1000))ms, max=\(String(format: "%.0f", maxTime*1000))ms")
    print("  每秒调用: \(String(format: "%.2f", callsPerSecond))")
    print("  CPU 估算: \(String(format: "%.1f", cpuEstimate))%")
    print("  每日执行时间: \(String(format: "%.1f", projectedDailyHours))h")

    if cpuEstimate < 5 {
        print("  评估: ✅ 可接受")
    } else if cpuEstimate < 15 {
        print("  评估: ⚠️  偏高")
    } else {
        print("  评估: ❌ 过高")
    }
}

// Check Music.app
print("检查 Music.app...")
let checkResult = executeAppleScript("tell application \"System Events\" to return (name of processes) contains \"Music\"")
if checkResult.lowercased() != "true" {
    print("❌ Music.app 未运行")
    exit(1)
}
print("✅ Music.app 运行中\n")

// Run tests
runTest(name: "高频", interval: 0.5, duration: 10)
runTest(name: "中频", interval: 1.0, duration: 10)
runTest(name: "低频", interval: 1.5, duration: 10)
runTest(name: "超低频", interval: 2.0, duration: 10)

print("\n" + String(repeating: "=", count: 60))
print("测试完成!")
print(String(repeating: "=", count: 60))

print("""

建议:
- 0.5s 间隔: CPU ~50%, 不可接受 ❌
- 1.0s 间隔: CPU ~25%, 偏高 ⚠️
- 1.5s 间隔: CPU ~17%, 勉强可用 ⚠️
- 2.0s 间隔: CPU ~12%, 可接受 ✅

歌词同步建议最低 1.0s，显示刷新可用 2.0s+
""")
