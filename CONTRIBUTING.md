# 参与贡献

kmgccc_player 由个人维护，合并节奏和方向会受维护时间影响。改动前把问题范围收窄、把验证结果写清楚，通常比一次改动很多区域更容易审阅。

## 开始之前

新分支从最新 `main` 建立：

```sh
git switch main
git pull --ff-only origin main
git switch -c your-branch-name
```

不要把与改动无关的本地文件、格式化结果或历史实验带入 PR。

## 搭建开发环境

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
./scripts/bootstrap.sh
./scripts/verify.sh
open kmgccc_player.xcodeproj
```

## 选择 Issue

小修复、拼写修正和文档修正可以直接提交 PR。以下改动建议先开 Issue，说明使用场景和可能影响的模块：

- 新功能、交互调整或会改变现有默认行为的改动；
- 新增、替换或升级第三方依赖；
- 修改 AMLL fork、歌词 timing、播放状态模型、曲库数据或导入流程；
- 跨多个界面或服务重构的改动。

安全问题不要开公开 Issue，处理方式见 `SECURITY.md`。

## 验证改动

`verify.sh` 是提交前的最低验证要求，包含依赖准备、ARM64 无签名 Debug 构建、LRC 回归、XCTest 和 App bundle 检查。如果只改了一个外部组件，可以先单独验证：

```sh
./scripts/bootstrap.sh --check --component mediaremote
./scripts/bootstrap.sh --force --component mediaremote
```

组件名：`amll`、`lddc`、`qqmusic-helper`、`mediaremote`、`sacad`。

## 提交 Pull Request

PR 描述至少写清：

- 要解决的问题和改动范围；
- 关键实现选择和没有覆盖的边界；
- 实际运行过的命令和结果；
- 相关 Issue。

UI 改动附修改前后截图。动画、全屏或歌词改动最好附短视频，并说明测试过的窗口状态和播放来源。新功能或新增文案需要检查现有本地化，不要把用户可见字符串直接散落在代码里。

## 高风险区域

以下模块改动后需要额外验证：

- **AMLL 与歌词 timing**：区分窗口歌词、全屏、cover blur、seek、暂停与恢复、重叠行和 lead-in。
- **播放来源切换**：分别验证本地播放、Apple Music 和系统正在播放。
- **外部 helper**：修改后单独检查对应组件和 App bundle 路径。
- **曲库持久化与迁移**：验证 sidecar 读写和迁移逻辑。
- **全屏与皮肤**：确认普通 Now Playing、全屏和主窗口内嵌三条路径。
- **封面颜色和频谱**：验证主题切换和可视化状态。

## 代码和仓库卫生

- 只提交属于本仓库的代码、文档、配置和测试。
- 不要提交 `.build/`、DerivedData、PyInstaller 中间目录、下载归档、App bundle、密钥、用户数据或本机绝对路径。
- 不要做与改动无关的大规模格式化、改名或文件搬迁。
- 不要手工修改 `kmgccc_player/Resources/AMLL/` 下的生成 bundle——AMLL 源码改动应在 submodule fork 完成，再由同步脚本生成。
- QQ Music API 只能经 bundled helper 使用，不要在 Swift 中直接调用第三方 API。
