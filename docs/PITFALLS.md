# 实现约束与坑（PITFALLS）

只收录**当前仍然生效**的实现约束与已知坑。改对应功能代码前先读本页；条目失效时直接改写或删除，不保留历史版本。

## 歌词渲染（NativeLyrics 与 AMLL 背景）

- 生产环境歌词只采用原生 `NativeLyrics` 引擎（Core Text + Core Animation）；不要在歌词渲染层中引入 DOM、JavaScript bridge 或歌词 WebView fallback。
- `kmgccc_player/Resources/AMLL/` 只保留网格背景所需的 `background.html`、生成的 `amll-background.js` 和字体资源；生成 JavaScript 不可手改，用 `scripts/sync-amll-from-fork.sh` 从 fork 同步。
- `AMLLMeshGradientBackgroundView` 的 WebView 只服务背景动画，不得复用于歌词，也不要在歌词 View 中创建第二套渲染状态。

## 全屏

- 系统全屏、窗口模拟全屏、主窗口内嵌是**三条独立路径**：样式、遮挡、过渡各自维护。修好其中一条不代表另外两条没问题；涉及全屏的改动三条都要人工检查。

## 播放来源与展示

- 改跨来源展示字段（本地 / Apple Music / 系统 Now Playing）时，本地与外部两条链路都要查。
- 改播放来源或展示模型时，要过一遍 Now Playing、MiniPlayer、全屏、歌词、Dock、遥测——它们都消费 `NowPlayingPresentation` 统一发布。
- 控制命令一律进 `PlaybackCoordinator`；不要在 UI 层另开控制通道。

## 主题与频谱

- 主题颜色只经 `ThemeStore` / `SemanticPalette`；绕过它们直接取色会在深浅色切换与 P3 输出上出问题。
- 频谱视图共享 `LEDMeterServiceProvider` / `AudioAnalysisHub` 分析服务；**禁止**为单个视图另装 AVAudioEngine tap。

## 外部组件

- 外部组件一律从 `Bundle.main.resourceURL` 解析；不要添加系统 Python、venv 或环境变量 fallback。
- Swift 不直接调用 QQMusicApi 或其他第三方 API；QQMusic 只经 bundle 内 `qqmusic-helper`（stdout 只输出 JSON，诊断走 stderr）。

## 工程

- 工程使用 Xcode **文件夹同步组**（PBXFileSystemSynchronizedRootGroup，无 membershipExceptions）：在同步目录里新建 `.swift` 文件即自动入 target，不需要也不应该手改 project.pbxproj 登记文件。
- 两套测试定位不同：`kmgccc_playerTests/` 是挂在 scheme 上的 XCTest target；`Tests/` 是用 `xcrun swiftc -parse-as-library` 直接编译被测源码的轻量脚本回归（刻意不依赖 App / SwiftData target）。新增测试先想清楚进哪条轨。
- 日志使用现有 `Log` 分类，**不加临时 `print`**——严禁在业务逻辑中引入裸 print，统一走现有 `Log` 分类。

## 提交与验证

- 常规改动 = 匹配的增量 Debug Build；`./scripts/verify.sh` 留给合并/PR/发布门禁；发布审计与私有资源验证**不进** verify.sh。
- 本仓库常有并行会话同时工作：动 git 分支、删产物、跑大规模清理前，先 `git status` + `git log` 确认没人在干活；squash 合并的分支不是 main 的祖先，删分支前先打 tag。
