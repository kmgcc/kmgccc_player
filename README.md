<p align="center">
  <img src="screenshots/Icon-iOS-Default-1024x1024@1x.png" width="192" alt="kmgccc_player Icon" />
</p>

<h1 align="center">kmgccc_player</h1>

<p align="center">
  面向 macOS 26 的本地音乐播放器。<br>
  原生开发，注重美学与沉浸式体验。
</p>

> [!WARNING]
> kmgccc_player 是个人项目，可能存在缺陷、未完成特性或行为变动。不建议在重要环境中作为唯一播放器使用。欢迎通过官网或 Issue 反馈问题。

[kmgccc_player 官网](https://player.kmgccc.cn)

## 主要功能

- **本地曲库**：管理本地音乐文件，支持按专辑、歌手、播放列表浏览和搜索，批量编辑元数据。
- **歌词显示**：基于 AMLL 实现类 Apple Music 的逐词歌词渲染，支持窗口、全屏和 MiniPlayer 多种歌词表面。
- **外部播放**：读取 Apple Music 和系统正在播放的信息，自动匹配歌词和封面。
- **多种皮肤**：内置多种 Now Playing 皮肤，支持全屏和多种可视化效果。
- **动态主题**：从封面提取色彩，自动生成界面主题和歌词颜色。
- **音频可视化**：实时频谱和波形显示，支持多种可视化样式。

## 系统要求

- macOS 26.0 或更新版本
- Apple Silicon Mac

## 从源码构建

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
./scripts/bootstrap.sh
./scripts/verify.sh
open kmgccc_player.xcodeproj
```

如果已经用普通 `git clone` 下载，先补齐 submodule：

```sh
git submodule update --init --recursive
```

`bootstrap.sh` 会下载并构建 AMLL、LDDC Fetch Core、QQ Music Helper、MediaRemoteAdapter 和 SACAD 五个外部运行组件。首次运行需要下载依赖并编译多个 ARM64 产物，耗时较长；之后会比对源码和工具链状态，未变化的组件直接复用缓存。

`verify.sh` 在提交改动前运行，依次执行 bootstrap、ARM64 Debug 构建、LRC 回归测试、单元测试和 App bundle 检查。

构建并运行 Debug App：

```sh
./scripts/build_and_run.sh
```

验证 Release 构建及 App bundle 完整性：

```sh
./scripts/build_app.sh Release
```

本机可选构建输入通过 `Config/LocalOverrides.xcconfig` 配置；可从同目录的 `.example` 复制。该文件缺失时工程照常构建，`verify.sh` 与 `build_app.sh` 会显式禁用本机构建扩展，确保结果可由 clean clone 复现。

开发环境需要：

- Xcode 26.2 或更新版本（Swift 6）
- Node.js 22（含 Corepack）
- ARM64 Python 3.12
- CMake 3.15 或更新版本
- Git、curl 和 Xcode Command Line Tools

外部组件的详细说明见 `docs/dependencies.md`。

## 常见问题

- **AMLL submodule 缺失或 commit 不一致**：运行 `git submodule sync --recursive`，再 `git submodule update --init --recursive`。
- **找不到 node 或 corepack**：安装 Node.js 22，确认两个命令都在 PATH 中。
- **Python 版本或架构不符**：安装 ARM64 Python 3.12，或用 `KMGCCC_ARM_PYTHON=/path/to/python3.12 ./scripts/bootstrap.sh` 指定。
- **找不到 CMake**：安装 CMake 3.15 或更新版本（MediaRemoteAdapter 需要）。
- **Xcode 报外部组件产物缺失**：回到仓库根目录运行 `./scripts/bootstrap.sh`。
- **产物被判定为 stale**：用 `./scripts/bootstrap.sh --force --component <name>` 重建对应组件。失败时查看 `.build/logs/`。
- **Swift Package 解析失败**：确认网络可访问 GitHub 后重试。

## 参与贡献

缺陷和功能建议可提交到 [GitHub Issues](https://github.com/kmgcc/kmgccc_player/issues)。请先搜索已有 Issue，附上 macOS 版本、Mac 架构、复现步骤和预期结果。安全问题不要发公开 Issue，请按 `SECURITY.md` 的私密渠道报告。

贡献代码前请阅读 `CONTRIBUTING.md`。

## 致谢

本项目在开发过程中使用并修改了以下开源项目：

- **[applemusic-like-lyrics (AMLL)](https://github.com/amll-dev/applemusic-like-lyrics)** — 歌词渲染引擎，通过项目维护的 [integration fork](https://github.com/kmgcc/applemusic-like-lyrics-kmgcccplayer-integration) 集成
- **[LDDC](https://github.com/chenmozhijin/LDDC)** — 歌词获取与匹配
- **[apple-audio-visualization](https://github.com/taterboom/apple-audio-visualization)** — 音频频谱分析与可视化算法
- **[ncmdump](https://github.com/taurusxin/ncmdump)** — NCM 格式解密
- **[sacad](https://github.com/desbma/sacad)** — 专辑封面搜索与下载
- **[QQMusicApi](https://github.com/L-1124/QQMusicApi)** — QQ 音乐元数据与封面查询
- **[MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter)** — macOS 外部播放状态读取与控制
- **[WhatsNewKit](https://github.com/SvenTiigi/WhatsNewKit)** — 应用更新说明展示

## 美术素材版权声明

除代码及另有说明的第三方内容外，本项目相关的美术素材（包括界面插画、UI 装饰、皮肤、贴图、角色设计、图形元素及其他视觉素材）均为作者原创作品，著作权及相关权利均由作者保留。未经作者事先书面授权，不得复制、转载、分发、修改、改编、商用、二次创作、提取，或用于机器学习与生成式 AI 相关用途。

保留一切权利。Copyright © kmg. All rights reserved.

## 许可证

代码基于 GNU Affero General Public License v3.0 (AGPL-3.0) 发布。第三方组件遵循各自的开源许可证，详见应用内 About 页面及 `Licenses` 目录。
