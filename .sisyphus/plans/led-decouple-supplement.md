# LED 系统解耦补充计划

## 问题分析

### 当前架构问题
1. **全局 LED 开关**：`AppSettings.ledMeterEnabled` 控制所有皮肤的 LED 采样
2. **皮肤级开关**：每个皮肤有自己的 `showLEDMeter`（如 `skin.classicLED.showLEDMeter`）
3. **耦合问题**：`PlayerViewModel.shouldRunLevelMeter = settings.ledMeterEnabled && isLedEnabledForCurrentSkin`
   - 即使皮肤开关打开，如果全局开关关闭，LED 也不会工作
   - 全屏和主窗口共享同一个 LEDMeterService

### 用户期望
1. 皮肤内的 LED 开关直接控制采样（开启显示就采样，关闭就停止）
2. 移除设置菜单中的全局 LED Meter 采样开关
3. 全屏和主窗口可以独立控制 LED

## 解决方案

### 核心思路
- 移除全局 `ledMeterEnabled` 开关
- 皮肤的 `showLEDMeter` 直接控制采样的启动/停止
- 每个上下文（NowPlaying/Fullscreen）独立管理自己的 LED 需求

### 具体修改

#### 1. 移除全局 LED 开关（AppSettings）
- 移除 `ledMeterEnabled` 属性
- 移除相关配置

#### 2. 修改 PlayerViewModel
- 移除 `setLedMeterEnabled` 方法
- 修改 `shouldRunLevelMeter` 逻辑，只检查皮肤开关
- 简化 LED 控制逻辑

#### 3. 修改 SettingsView
- 移除 LED Meter 卡片的"启用 LED Meter 采样" Toggle
- 保留其他 LED 设置（LED 数量、灵敏度等）

#### 4. 修改皮肤实现
- ClassicLEDSkin：在 `showLEDMeter` 变化时直接控制 LEDMeterService
- KmgcccCassetteSkin：同上
- 可能需要添加环境变量访问 LEDMeterService

#### 5. 全屏模式独立控制
- FullscreenPlayerView 独立管理 LED 采样
- 不依赖主窗口的 LED 状态

## 修改清单

### Task A: 移除 AppSettings 全局 LED 开关
**文件**: `Models/AppSettings.swift`
- 移除 `@AppStorage("ledMeterEnabled") var ledMeterEnabled: Bool`
- 移除相关初始化代码

### Task B: 修改 PlayerViewModel LED 逻辑
**文件**: `ViewModels/PlayerViewModel.swift`
- 移除 `setLedMeterEnabled` 方法
- 修改 `shouldRunLevelMeter` 只检查皮肤开关
- 简化 `refreshLedMeterStateFromSettings`

### Task C: 移除 SettingsView 全局 LED 开关
**文件**: `Views/Settings/SettingsView.swift`
- 移除 `ledMeterEnabled` @State 变量
- 移除 "启用 LED Meter 采样" Toggle
- 移除相关 sync 逻辑

### Task D: 修改皮肤 LED 控制
**文件**: 
- `Skins/NowPlaying/ClassicLEDSkin.swift`
- `Skins/NowPlaying/KmgcccCassetteSkin.swift`

**修改内容**:
- 在 `showLEDMeter` 的 `.onChange` 中直接控制 LEDMeterService
- 添加环境变量访问 LEDMeterService
- 皮肤显示时根据 `showLEDMeter` 启动/停止采样

### Task E: 修改 NowPlayingHostView
**文件**: `Views/NowPlaying/NowPlayingHostView.swift`
- 根据当前皮肤的 `showLEDMeter` 控制 LEDMeterService

### Task F: 修改 FullscreenPlayerView
**文件**: `Views/Fullscreen/FullscreenPlayerView.swift`
- 根据全屏皮肤的 `showLEDMeter` 独立控制 LEDMeterService
- 不依赖主窗口的 LED 状态

### Task G: 更新 RotatingCoverSkin（如果有 LED 选项）
**文件**: `Skins/NowPlaying/RotatingCoverSkin.swift`
- 检查是否有 LED 相关选项
- 如有，做同样修改

## 关键代码示例

### 皮肤 LED 控制示例
```swift
// 在皮肤的 makeArtwork 或 settingsView 中
@AppStorage("skin.classicLED.showLEDMeter") private var showLEDMeter: Bool = false

// 在 .onChange 中
.onChange(of: showLEDMeter) { _, newValue in
    if newValue {
        ledMeter.start()
    } else {
        ledMeter.stop()
    }
}

// 在视图显示时
.onAppear {
    if showLEDMeter {
        ledMeter.start()
    }
}
.onDisappear {
    ledMeter.stop()
}
```

## 验收标准
- [ ] 设置菜单中移除了"启用 LED Meter 采样"开关
- [ ] 皮肤内的 LED 开关直接控制采样（开启就采样，关闭就停止）
- [ ] 全屏和主窗口可以独立控制 LED
- [ ] LED 数量、灵敏度等其他设置仍然可用
- [ ] 所有皮肤（ClassicLED、Cassette、RotatingCover）正常工作
- [ ] 构建成功
