# LED/Spectrum 开关全屏解耦补充计划

## 问题分析

### 当前实现
皮肤使用 `@AppStorage` 存储开关状态，但键名不区分模式：
```swift
@AppStorage("skin.classicLED.showLEDMeter") private var showLEDMeter: Bool = false
@AppStorage("skin.classicLED.showPillSpectrum") private var showPillSpectrum: Bool = false
```

### 问题
- 普通模式和全屏模式共用同一个 UserDefaults 键
- 在普通模式开关 LED，全屏模式也会同步变化
- 反之亦然

## 解决方案

### 核心思路
为全屏模式创建独立的存储键，让普通模式和全屏模式完全独立。

### 键名映射

**ClassicLEDSkin**:
- 普通模式: `skin.classicLED.showLEDMeter`
- 全屏模式: `skin.classicLED.fullscreen.showLEDMeter`
- 普通模式: `skin.classicLED.showPillSpectrum`
- 全屏模式: `skin.classicLED.fullscreen.showPillSpectrum`

**RotatingCoverSkin**:
- 普通模式: `skin.rotatingCover.showPillSpectrum`
- 全屏模式: `skin.rotatingCover.fullscreen.showPillSpectrum`

**KmgcccCassetteSkin**:
- 普通模式: `skin.kmgcccCassette.showLEDMeter`
- 全屏模式: `skin.kmgcccCassette.fullscreen.showLEDMeter`

## 实施计划

### Task H: 修改 ClassicLEDSkin 支持双模式存储

**文件**: `Skins/NowPlaying/ClassicLEDSkin.swift`

**修改内容**:

1. **修改 artwork view 中的存储属性** (around line 35-36):
   ```swift
   // 移除固定的 @AppStorage
   // @AppStorage("skin.classicLED.showLEDMeter") private var showLEDMeter: Bool = false
   // @AppStorage("skin.classicLED.showPillSpectrum") private var showPillSpectrum: Bool = false
   
   // 改为使用计算属性，根据 isFullscreen 返回不同键的值
   @StateObject private var fullscreenManager = FullscreenWindowManager.shared
   
   // 使用自定义 getter/setter 访问 UserDefaults
   private var showLEDMeter: Bool {
       get {
           let key = fullscreenManager.isFullscreenActive ? 
               "skin.classicLED.fullscreen.showLEDMeter" : 
               "skin.classicLED.showLEDMeter"
           return UserDefaults.standard.bool(forKey: key)
       }
       nonmutating set {
           let key = fullscreenManager.isFullscreenActive ? 
               "skin.classicLED.fullscreen.showLEDMeter" : 
               "skin.classicLED.showLEDMeter"
           UserDefaults.standard.set(newValue, forKey: key)
       }
   }
   
   private var showPillSpectrum: Bool {
       get {
           let key = fullscreenManager.isFullscreenActive ? 
               "skin.classicLED.fullscreen.showPillSpectrum" : 
               "skin.classicLED.showPillSpectrum"
           return UserDefaults.standard.bool(forKey: key)
       }
       nonmutating set {
           let key = fullscreenManager.isFullscreenActive ? 
               "skin.classicLED.fullscreen.showPillSpectrum" : 
               "skin.classicLED.showPillSpectrum"
           UserDefaults.standard.set(newValue, forKey: key)
       }
   }
   ```


**修改内容**:


## 实施

### Task H: 修改 ClassicLEDSkin

**文件**: `Skins

1. **移除固定的 `@AppStorage`** (line 35-36)
2. **添加动态键访问** 使用计算属性
3. **修改 SettingsView** 支持双模式

### Task I: 修改 RotatingCoverSkin
**文件**: `Skins/NowPlaying/RotatingCoverSkin.swift`
- 为 `showPillSpectrum` 添加双模式存储

### Task J: 修改 CassetteSkin
**文件**: `Skins/NowPlaying/KmgcccCassetteSkin.swift`
- 为 `showLEDMeter` 添加双模式存储

### Task K: 更新 SettingsView 显示双模式设置
**文件**: `Views/Settings/SettingsView.swift`
- 在 Fullscreen 设置中添加皮肤 LED/Spectrum 开关
- 独立控制全屏模式的开关

## 关键代码模式

```swift
// 动态键访问模式
private var showLEDMeter: Bool {
    get {
        let key = isFullscreen ? "skin.xxx.fullscreen.showLEDMeter" : "skin.xxx.showLEDMeter"
        return UserDefaults.standard.bool(forKey: key)
    }
    nonmutating set {
        let key = isFullscreen ? "skin.xxx.fullscreen.showLEDMeter" : "skin.xxx.showLEDMeter"
        UserDefaults.standard.set(newValue, forKey: key)
    }
}
```

## 数据迁移
- 新安装: 全屏模式默认关闭 (false)
- 现有用户: 全屏模式需要重新设置（因为使用新键）

## 验收标准
- [ ] ClassicLEDSkin 普通模式和全屏模式 LED 开关独立
- [ ] ClassicLEDSkin 普通模式和全屏模式 Spectrum 开关独立
- [ ] RotatingCoverSkin 普通模式和全屏模式 Spectrum 开关独立
- [ ] CassetteSkin 普通模式和全屏模式 LED 开关独立
- [ ] SettingsView 可以为全屏模式单独设置皮肤选项
- [ ] 构建成功
