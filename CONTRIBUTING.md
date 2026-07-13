# 参与贡献

kmgccc_player 是个人维护项目。合并节奏和方向会受维护时间影响；提交前把问题范围收窄、把验证结果写清，通常比一次改动很多区域更容易审阅。

## 从 main 开始

新分支应从最新 `main` 建立：

```sh
git switch main
git pull --ff-only origin main
git switch -c your-branch-name
```

不要把与本次改动无关的本地文件、格式化结果或历史实验一并带入 PR。

## 什么时候先开 Issue

以下改动建议先开 Issue，说明使用场景、预期行为和可能影响的模块：

- 新功能、较大的交互调整或会改变现有默认行为的改动；
- 新增、替换或升级第三方依赖；
- 修改 AMLL fork、歌词 timing、播放状态模型、曲库数据或导入流程；
- 需要跨多个界面或服务重构的改动。

范围明确的小缺陷、测试补充、拼写修正和文档修正，可以直接提交 PR。安全问题不要开公开 Issue，处理方式见 `SECURITY.md`。

## 初始化、构建和测试

新环境使用带 submodule 的 clone：

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
./scripts/bootstrap.sh
./scripts/verify.sh
open kmgccc_player.xcodeproj
```

`./scripts/verify.sh` 是提交前的最低验证要求，它包含依赖准备、arm64 无签名 Debug 构建、LRC 回归、XCTest 和 App bundle 检查。只改一个外部组件时，可先运行：

```sh
./scripts/bootstrap.sh --check --component mediaremote
./scripts/bootstrap.sh --force --component mediaremote
```

上面以 MediaRemoteAdapter 为例；组件名可换成 `amll`、`lddc`、`qqmusic-helper` 或 `sacad`。

## PR 应包含什么

PR 描述至少写清：

- 要解决的问题和改动范围；
- 关键实现选择，以及没有覆盖的边界；
- 实际运行过的命令和结果；
- 需要维护者手工验证的项目；
- 相关 Issue，若没有则说明原因。

UI 改动请附修改前后截图；动画、全屏或歌词改动最好同时附短视频，并说明测试过的窗口状态和播放来源。新功能或新增文案需要检查简体中文和英文等现有本地化，不要把用户可见字符串直接散落在代码里。

## 提交边界

- 不要提交 `.build/`、DerivedData、PyInstaller 中间目录、下载归档或 App bundle。
- 不要提交私有美术资源、私有仓库内容、密钥、用户数据、日志中的曲库信息或 `/Users/...` 一类本机绝对路径。
- `docs-private/` 和 `PrivateArtSources/` 是独立 Git 仓库，不属于主仓库提交范围；公开文档放在 `docs/` 下，由主仓库跟踪。
- 不要为了顺手整理而做无关的大规模格式化、改名或文件搬迁。
- 不要手改 `kmgccc_player/Resources/AMLL/` 下的生成 bundle；AMLL 源码改动应在 submodule fork 完成，再由同步脚本生成。
- QQ Music API 只能经 bundled helper 使用；不要在 SwiftUI 视图中直接调用第三方 API，也不要恢复系统 Python 或开发目录 fallback。

## 高风险模块

AMLL 与歌词 timing、本地和外部播放切换、曲库持久化与迁移、文件导入、全屏与皮肤、封面颜色和频谱、外部 helper、Xcode Build Phases 都属于高风险区域。修改这些部分时，PR 还应说明状态所有者、数据流、失败时的退化行为，并列出相关回归。

AMLL 改动需区分窗口歌词、全屏、cover blur、seek、暂停与恢复、重叠行和 lead-in；外部播放改动需分别验证本地播放、Apple Music 和系统正在播放。依赖或打包改动除 `./scripts/verify.sh` 外，还应单独检查对应组件和最终 App bundle 路径。
