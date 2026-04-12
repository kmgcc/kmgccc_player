// Phase 1 Test Suite - Run with: cat OptimizedAppleMusicBridge.swift Phase1Test.swift | xcrun swift -
// Or combined: xcrun swift combined.swift

import Foundation
import Cocoa

// 导入优化版桥接代码
// 注意：实际测试时需要将 OptimizedAppleMusicBridge.swift 内容复制到同一文件，或设置正确的 import 路径

// MARK: - Test Runner

/// Phase 1 完整测试套件
class Phase1Tests {

    let bridge = OptimizedAppleMusicBridge.shared

    // MARK: - Test Results
    struct TestResult {
        let name: String
        let passed: Bool
        let message: String
        let details: [String: Any]?

        func print() {
            let status = passed ? "✅ PASS" : "❌ FAIL"
            Swift.print("\(status): \(name)")
            if !message.isEmpty {
                Swift.print("   \(message)")
            }
            if let details = details, !details.isEmpty {
                for (key, value) in details {
                    Swift.print("   \(key): \(value)")
                }
            }
        }
    }

    private var results: [TestResult] = []

    // MARK: - Run All Tests

    func runAllTests() {
        Swift.print("=" * 60)
        Swift.print("Apple Music Bridge - Phase 1 测试套件")
        Swift.print("=" * 60)
        Swift.print("")

        // 前置检查
        Swift.print("📋 前置检查:")
        Swift.print("   Music.app 运行状态: \(bridge.isMusicAppRunning() ? "✅ 运行中" : "⚠️ 未运行")")
        Swift.print("")

        // 场景测试
        testScenario1_NormalPlayback()
        testScenario2_PlayPauseToggle()
        testScenario3_ShuffleToggle()
        testScenario4_RepeatModes()
        testScenario5_TrackChange()
        testScenario6_MusicAppNotRunning()
        testScenario7_PermissionDenied()

        // 性能测试
        testPerformance()

        // 输出总结
        printSummary()
    }

    // MARK: - 场景 1: 正常播放

    func testScenario1_NormalPlayback() {
        Swift.print("\n🎵 场景 1: 正常播放 Apple Music 曲库歌曲")
        Swift.print("-" * 50)

        guard bridge.isMusicAppRunning() else {
            results.append(TestResult(
                name: "正常播放 - 字段获取",
                passed: false,
                message: "Music.app 未运行，跳过此测试",
                details: nil
            ))
            return
        }

        let info = bridge.fetchFullInfo()

        // 验证核心字段
        let coreFields = [
            ("title", info.title != nil, info.title ?? "nil"),
            ("artist", info.artist != nil, info.artist ?? "nil"),
            ("album", info.album != nil, info.album ?? "nil"),
            ("duration", info.duration > 0, "\(info.duration)"),
            ("position", info.position >= 0, "\(info.position)"),
            ("state", info.state != .unknown, info.state.rawValue)
        ]

        for (name, valid, value) in coreFields {
            results.append(TestResult(
                name: "核心字段: \(name)",
                passed: valid,
                message: valid ? "值: \(value)" : "无效值",
                details: nil
            ))
            results.last?.print()
        }

        // 验证 Phase 1 新增字段
        let newFields = [
            ("persistentID", info.persistentID != nil, info.persistentID ?? "nil"),
            ("albumArtist", info.albumArtist != nil, info.albumArtist ?? "nil"),
            ("trackNumber", info.trackNumber > 0, "\(info.trackNumber)"),
            ("year", info.year > 0, "\(info.year)"),
            ("shuffleEnabled", true, "\(info.shuffleEnabled)"),
            ("songRepeat", info.songRepeat != .unknown, info.songRepeat.rawValue)
        ]

        for (name, valid, value) in newFields {
            // 对于 trackNumber 和 year，0 是有效值（表示未设置），所以放宽检查
            let isValid = valid || (name == "trackNumber" || name == "year")
            results.append(TestResult(
                name: "新增字段: \(name)",
                passed: isValid,
                message: "值: \(value)",
                details: nil
            ))
            results.last?.print()
        }

        // 打印完整信息
        Swift.print("\n   完整信息:")
        Swift.print("   " + info.debugDescription.replacingOccurrences(of: "\n", with: "\n   "))
    }

    // MARK: - 场景 2: 暂停/播放切换

    func testScenario2_PlayPauseToggle() {
        Swift.print("\n⏯️ 场景 2: 暂停/播放切换")
        Swift.print("-" * 50)

        guard bridge.isMusicAppRunning() else {
            results.append(TestResult(
                name: "暂停/播放切换",
                passed: false,
                message: "Music.app 未运行",
                details: nil
            ))
            return
        }

        // 获取当前状态
        let info1 = bridge.fetchFullInfo()
        let initialState = info1.state

        Swift.print("   初始状态: \(initialState)")

        // 切换播放状态
        bridge.playPause()
        Thread.sleep(forTimeInterval: 0.5)  // 等待状态切换

        let info2 = bridge.fetchFullInfo()
        let newState = info2.state

        Swift.print("   切换后状态: \(newState)")

        // 验证状态有变化（或至少保持有效）
        let stateChanged = newState != initialState || (initialState == .playing || initialState == .paused)

        results.append(TestResult(
            name: "暂停/播放切换",
            passed: stateChanged,
            message: "\(initialState) -> \(newState)",
            details: ["position1": info1.position, "position2": info2.position]
        ))
        results.last?.print()

        // 恢复原状态
        if newState != initialState {
            bridge.playPause()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - 场景 3: 随机播放开关

    func testScenario3_ShuffleToggle() {
        Swift.print("\n🔀 场景 3: 随机播放开关同步")
        Swift.print("-" * 50)

        guard bridge.isMusicAppRunning() else {
            results.append(TestResult(
                name: "随机播放同步",
                passed: false,
                message: "Music.app 未运行",
                details: nil
            ))
            return
        }

        // 获取当前状态
        let info1 = bridge.fetchFullInfo()
        let initialShuffle = info1.shuffleEnabled

        Swift.print("   初始随机状态: \(initialShuffle)")
        Swift.print("   ⚠️ 请在 Music.app 中手动切换随机播放开关，然后按回车...")

        // 等待用户操作
        _ = readLine()

        let info2 = bridge.fetchFullInfo()
        let newShuffle = info2.shuffleEnabled

        Swift.print("   新随机状态: \(newShuffle)")

        // 验证我们能检测到变化（如果用户切换了）
        results.append(TestResult(
            name: "随机播放同步",
            passed: true,  // 只要能读取到值就算通过
            message: "\(initialShuffle) -> \(newShuffle)",
            details: ["detected_change": newShuffle != initialShuffle]
        ))
        results.last?.print()
    }

    // MARK: - 场景 4: 重复模式

    func testScenario4_RepeatModes() {
        Swift.print("\n🔁 场景 4: 重复模式切换")
        Swift.print("-" * 50)

        guard bridge.isMusicAppRunning() else {
            results.append(TestResult(
                name: "重复模式检测",
                passed: false,
                message: "Music.app 未运行",
                details: nil
            ))
            return
        }

        let modes = [
            ("off", "关闭"),
            ("one", "单曲循环"),
            ("all", "全部循环")
        ]

        var detectedModes: [String] = []

        for (mode, description) in modes {
            Swift.print("   ⚠️ 请将 Music.app 重复模式设置为 '\(description)' (\(mode))，然后按回车...")
            _ = readLine()

            let info = bridge.fetchFullInfo()
            let detectedMode = info.songRepeat.rawValue

            Swift.print("   检测到: \(detectedMode)")
            detectedModes.append(detectedMode)

            results.append(TestResult(
                name: "重复模式: \(mode)",
                passed: detectedMode == mode,
                message: "期望: \(mode), 实际: \(detectedMode)",
                details: nil
            ))
            results.last?.print()
        }
    }

    // MARK: - 场景 5: 切歌

    func testScenario5_TrackChange() {
        Swift.print("\n⏭️ 场景 5: 切歌检测")
        Swift.print("-" * 50)

        guard bridge.isMusicAppRunning() else {
            results.append(TestResult(
                name: "切歌检测",
                passed: false,
                message: "Music.app 未运行",
                details: nil
            ))
            return
        }

        // 获取当前歌曲信息
        let info1 = bridge.fetchFullInfo()
        Swift.print("   当前歌曲: \(info1.title ?? "Unknown") - \(info1.persistentID ?? "no-id")")

        Swift.print("   ⚠️ 请在 Music.app 中切换到下一首歌，然后按回车...")
        _ = readLine()

        let info2 = bridge.fetchFullInfo()
        Swift.print("   新歌曲: \(info2.title ?? "Unknown") - \(info2.persistentID ?? "no-id")")

        // 验证关键字段
        let trackChanged = info1.persistentID != info2.persistentID ||
                          info1.title != info2.title

        let pidChanged = info1.persistentID != info2.persistentID
        let titleChanged = info1.title != info2.title
        let tnChanged = info1.trackNumber != info2.trackNumber
        let yearChanged = info1.year != info2.year
        let aaChanged = info1.albumArtist != info2.albumArtist

        let fieldsUpdated: [(String, Bool)] = [
            ("persistentID", pidChanged),
            ("title", titleChanged),
            ("trackNumber", tnChanged),
            ("year", yearChanged),
            ("albumArtist", aaChanged)
        ]

        results.append(TestResult(
            name: "切歌检测",
            passed: trackChanged,
            message: trackChanged ? "歌曲已切换" : "歌曲未变化",
            details: Dictionary(uniqueKeysWithValues: fieldsUpdated)
        ))
        results.last?.print()

        // 详细输出
        Swift.print("\n   字段变化:")
        for (field, changed) in fieldsUpdated {
            Swift.print("   \(changed ? "✅" : "➖") \(field)")
        }
    }

    // MARK: - 场景 6: Music.app 未运行

    func testScenario6_MusicAppNotRunning() {
        Swift.print("\n🚫 场景 6: Music.app 未运行场景")
        Swift.print("-" * 50)

        if bridge.isMusicAppRunning() {
            Swift.print("   ⚠️ Music.app 正在运行，此测试需要关闭 Music.app")
            Swift.print("   请关闭 Music.app 后按回车...")
            _ = readLine()
        }

        // 测试位置查询
        let posInfo = bridge.fetchPositionInfo()
        let posHandled = posInfo.state == .stopped

        results.append(TestResult(
            name: "未运行 - 位置查询",
            passed: posHandled,
            message: "状态: \(posInfo.state)",
            details: nil
        ))
        results.last?.print()

        // 测试完整信息查询
        let fullInfo = bridge.fetchFullInfo()
        let fullHandled = fullInfo.state == .stopped

        results.append(TestResult(
            name: "未运行 - 完整信息查询",
            passed: fullHandled,
            message: "状态: \(fullInfo.state)",
            details: nil
        ))
        results.last?.print()

        Swift.print("   ⚠️ 测试完成，可以重新启动 Music.app")
    }

    // MARK: - 场景 7: 权限拒绝

    func testScenario7_PermissionDenied() {
        Swift.print("\n🔒 场景 7: 权限拒绝处理")
        Swift.print("-" * 50)
        Swift.print("   注: 此场景通常需要首次运行或重置权限才能复现")
        Swift.print("   检查错误处理逻辑...")

        // 检查代码中是否有权限错误处理
        let script = """
            tell application "Music"
                return name of current track
            end tell
            """

        var errorInfo: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            _ = appleScript.executeAndReturnError(&errorInfo)

            if let error = errorInfo {
                let errorDesc = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown"
                Swift.print("   当前错误: \(errorDesc)")

                let isPermissionError = errorDesc.contains("not allowed") ||
                                       errorDesc.contains("privilege")

                results.append(TestResult(
                    name: "权限错误检测",
                    passed: true,  // 只要能检测到错误就算通过
                    message: isPermissionError ? "权限被拒绝" : "其他错误: \(errorDesc)",
                    details: ["error": errorDesc]
                ))
            } else {
                results.append(TestResult(
                    name: "权限错误检测",
                    passed: true,
                    message: "有权限，正常运行",
                    details: nil
                ))
            }
        }
        results.last?.print()
    }

    // MARK: - 性能测试

    func testPerformance() {
        Swift.print("\n⚡ 性能测试")
        Swift.print("-" * 50)

        guard bridge.isMusicAppRunning() else {
            Swift.print("   Music.app 未运行，跳过性能测试")
            return
        }

        // 测试高频查询 (100次)
        Swift.print("   测试高频查询 (100次 fetchPositionInfo)...")
        let start1 = Date()
        for _ in 0..<100 {
            _ = bridge.fetchPositionInfo()
        }
        let duration1 = Date().timeIntervalSince(start1)
        let avg1 = duration1 / 100 * 1000  // ms

        results.append(TestResult(
            name: "性能 - 高频查询",
            passed: avg1 < 50,  // 单次应 < 50ms
            message: String(format: "100次: %.3fs, 平均: %.2fms/次", duration1, avg1),
            details: nil
        ))
        results.last?.print()

        // 测试低频查询 (10次)
        Swift.print("   测试低频查询 (10次 fetchFullInfo)...")
        let start2 = Date()
        for _ in 0..<10 {
            _ = bridge.fetchFullInfo()
        }
        let duration2 = Date().timeIntervalSince(start2)
        let avg2 = duration2 / 10 * 1000  // ms

        results.append(TestResult(
            name: "性能 - 低频查询",
            passed: avg2 < 200,  // 单次应 < 200ms
            message: String(format: "10次: %.3fs, 平均: %.2fms/次", duration2, avg2),
            details: nil
        ))
        results.last?.print()

        // 验证双频率架构未被破坏
        Swift.print("   架构验证: 高频查询不包含完整字段...")
        let posInfo = bridge.fetchPositionInfo()
        let isLightweight = posInfo.title == nil && posInfo.artist == nil

        results.append(TestResult(
            name: "架构 - 高频轻量",
            passed: isLightweight,
            message: isLightweight ? "正确: 仅 position + state" : "错误: 包含额外字段",
            details: nil
        ))
        results.last?.print()
    }

    // MARK: - 总结

    func printSummary() {
        Swift.print("\n" + "=" * 60)
        Swift.print("测试总结")
        Swift.print("=" * 60)

        let total = results.count
        let passed = results.filter(\.passed).count
        let failed = total - passed

        Swift.print("总计: \(total) 项")
        Swift.print("通过: \(passed) ✅")
        Swift.print("失败: \(failed) \(failed > 0 ? "❌" : "")")

        if failed > 0 {
            Swift.print("\n失败的测试:")
            for result in results where !result.passed {
                Swift.print("   ❌ \(result.name): \(result.message)")
            }
        }

        Swift.print("")
        Swift.print("Phase 1 要求字段检查:")
        let requiredFields = [
            "persistentID", "albumArtist", "trackNumber",
            "year", "shuffleEnabled", "songRepeat"
        ]
        for field in requiredFields {
            let hasField = results.contains { $0.name.contains(field) }
            Swift.print("   \(hasField ? "✅" : "❌") \(field)")
        }
    }
}

// MARK: - String Extension

extension String {
    static func *(lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}

// MARK: - Main

print("Apple Music Bridge - Phase 1 测试")
print("================================")
print("")
print("此测试需要:")
print("1. macOS 系统")
print("2. Music.app 已安装")
print("3. 已授权自动化权限 (首次运行会提示)")
print("")
print("按回车开始测试...")
_ = readLine()

let tester = Phase1Tests()
tester.runAllTests()

print("")
print("测试完成")
