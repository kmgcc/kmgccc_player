<p align="center">
  <img src="screenshots/Icon-iOS-Default-1024x1024@1x.png" width="192" alt="kmgccc_player Icon" />
</p>

<h1 align="center">kmgccc_player</h1>

<p align="center">
  面向 <strong>macOS 26</strong> 的本地音乐播放器<br>
  原生开发、专注美学，致力于沉浸式且富有特色的播放体验
</p>


> [!WARNING]
> kmgccc_player 为个人项目，可能存在 Bug、未完成特性或行为变动。
> 不建议在重要环境中作为唯一播放器使用，欢迎通过官网表单或者 Issue 反馈问题。也欢迎提出你的意见和创意～
> 代码使用 AI 生成，可能存在问题。

[看看 kmgccc_player](https://player.kmgccc.cn)

## 项目简介

kmgccc_player 是一个以本地曲库为主的 macOS 音乐播放器，也可读取 Apple Music 和系统正在播放的信息。项目仍由个人维护，界面、歌词、外部播放和依赖打包等部分都可能继续调整；源码可供使用和贡献，但不应把当前版本当作已经稳定的通用播放器框架。

## 开发环境

当前工程和 CI 使用以下环境：

- macOS 26.0 或更新版本；
- Apple Silicon（arm64）；
- Xcode 26.2 或更新版本，工程使用 Swift 6；
- Node.js 22，并提供 Corepack；
- arm64 Python 3.12；
- CMake 3.15 或更新版本；
- Git、curl 和 Xcode Command Line Tools。

Intel Mac 不在当前源码构建范围内。Xcode 工程的 App deployment target 是 macOS 26.0，统一验证命令固定构建 arm64。

## 快速开始

请使用 Git 克隆仓库。GitHub 的“Download ZIP”不包含 AMLL submodule，不能代替下面的命令。

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
./scripts/bootstrap.sh
./scripts/verify.sh
open kmgccc_player.xcodeproj
```

在 Xcode 中选择 `kmgccc_player` scheme 和本机 Mac 即可继续调试。若仓库已经用普通 `git clone` 下载，先补齐 submodule：

```sh
git submodule update --init --recursive
```

## Bootstrap 做了什么

`scripts/bootstrap.sh` 是外部运行组件的统一入口。它会检查 AMLL submodule，构建 AMLL、LDDC Fetch Core 和 QQ Music Helper，并下载、校验和准备固定版本的 MediaRemoteAdapter 与 SACAD。下载缓存、中间目录和可复制产物统一放在 `.build/`；AMLL 的四个生成文件还会同步到 `kmgccc_player/Resources/AMLL/`，供 Xcode 的 Resources 阶段打包。

第一次运行需要下载 Node/Python 依赖并编译多个 arm64 产物，通常会比普通 Xcode 构建慢。后续运行会比较源码、构建脚本、架构和工具链 stamp，未变化的组件直接复用缓存。

```sh
./scripts/bootstrap.sh --check
./scripts/bootstrap.sh --component lddc
./scripts/bootstrap.sh --force --component mediaremote
```

`--check` 只检查现有产物，不下载或编译；`--component` 只处理一个组件；`--force` 强制重建所选组件。

## 构建与验证

提交改动前运行：

```sh
./scripts/verify.sh
```

该脚本会依次运行 bootstrap、arm64 无签名 Debug 构建、LRC 回归程序、`kmgccc_playerTests`，最后检查 App bundle 中的必需组件和许可证。失败时终端会打印保留的临时目录和完整日志位置。

只做一次命令行 Debug 构建，可使用：

```sh
rm -rf /tmp/kmgccc-derived /tmp/kmgccc-packages
xcodebuild -quiet \
  -project kmgccc_player.xcodeproj \
  -scheme kmgccc_player \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/kmgccc-derived \
  -clonedSourcePackagesDirPath /tmp/kmgccc-packages \
  CODE_SIGNING_ALLOWED=NO \
  build
```

这个命令不会替你准备外部组件；新环境仍应先运行 bootstrap。

## 常见问题

- `AMLL` 报 submodule 缺失或 commit 不一致：运行 `git submodule sync --recursive`，再运行 `git submodule update --init --recursive`。
- 找不到 `node` 或 `corepack`：安装 Node.js 22，并确认两个命令都在 `PATH` 中。
- Python 版本或架构不符：安装 arm64 Python 3.12，或用 `KMGCCC_ARM_PYTHON=/path/to/python3.12 ./scripts/bootstrap.sh` 指定解释器。
- 找不到 CMake：安装 CMake 3.15 或更新版本；MediaRemoteAdapter 需要它生成 Xcode 工程。
- Xcode 报 LDDC、QQ Music Helper、MediaRemoteAdapter 或 SACAD 产物缺失：回到仓库根目录运行 `./scripts/bootstrap.sh`。
- 产物被判定为 stale：用 `--force --component` 重建对应组件；组件名见 `./scripts/bootstrap.sh --help`。仍失败时查看 `.build/logs/`。
- Swift Package 解析失败：确认网络可访问 GitHub 后重试。工程当前固定使用 WhatsNewKit 2.2.1。

## Issue 和 Pull Request

普通缺陷和功能建议可提交到 [GitHub Issues](https://github.com/kmgcc/kmgccc_player/issues)。请先搜索已有 Issue，并附上 macOS 版本、Mac 架构、复现步骤、预期结果和实际结果；日志里应先删去用户数据和本机路径。安全问题不要发公开 Issue，请按 `SECURITY.md` 的私密渠道报告。

贡献代码前请阅读 `CONTRIBUTING.md`。PR 应从 `main` 开始，说明改动范围和验证结果；UI 改动附截图，新功能补齐相关本地化，高风险模块还需写明回归范围。

## 第三方运行时

AMLL、LDDC Fetch Core、QQ Music Helper、MediaRemoteAdapter 和 SACAD 都由 bootstrap 固定来源或版本。Xcode 不会从用户目录、系统 Python 或仓库外的临时路径寻找这些运行组件。

## 注意事项

- app的数据文件存默认放在`/Users/username/Music/kmgccc_player Library`中, 删除、替换 app 不会删除数据文件

- 可以使用 `AMLL TTML Tool` 手动编辑 ttml 格式的歌词，操作更精准且可以启用 amll 的高级功能如背景歌词、对唱歌词。
项目地址：https://github.com/amll-dev/amll-ttml-tool
在线使用：https://amll-ttml-tool.stevexmh.net/
也欢迎给 AMLL DB 贡献歌词。

## 致谢

本项目在开发过程中使用并修改了以下开源项目：

- **applemusic-like-lyrics (AMLL)**<br>
  提供歌词渲染能力，实现类 Apple Music 的歌词显示效果。<br>
  https://github.com/amll-dev/applemusic-like-lyrics
  AMLL DB 歌词库：https://github.com/amll-dev/amll-ttml-db

- **LDDC (Lyrics Data Digging Core)**<br>
  提供歌词获取与匹配能力。<br>
  https://github.com/chenmozhijin/LDDC

- **apple-audio-visualization**<br>
  提供音频频谱分析与可视化算法，本项目在播放界面与磁带视图中使用并修改了其部分实现。<br>
  https://github.com/taterboom/apple-audio-visualization

- **ncmdump**<br>
  提供 NCM 格式解密能力，支持导入网易云音乐加密文件。<br>
  https://github.com/taurusxin/ncmdump

- **sacad**<br>
  提供专辑封面搜索与下载能力。<br>
  https://github.com/desbma/sacad

- **QQMusicApi**<br>
  提供 QQ 音乐元数据与封面候选查询能力。<br>
  https://github.com/L-1124/QQMusicApi

- **MediaRemote Adapter**
  提供 macOS 外部播放状态读取与控制能力。
  https://github.com/ungive/mediaremote-adapter

- **WhatsNewKit**<br>
  提供应用更新说明展示组件。<br>
  https://github.com/SvenTiigi/WhatsNewKit


## 美术素材版权声明

除代码及另有说明的第三方内容外，本项目相关的美术素材，包括但不限于界面插画、UI 装饰、皮肤、贴图、角色设计、图形元素、图像资源及其他视觉素材，均为作者原创作品，其著作权及其他相关权利均由作者保留。未经作者事先书面授权，不得复制、转载、分发、修改、改编、商用、二次创作、提取，或用于机器学习与生成式 AI 相关用途。

保留一切权利。
Copyright © kmg. All rights reserved.

## 许可证 (License)

本项目为开源软件，**代码** 基于 **GNU Affero General Public License v3.0 (AGPL-3.0)** 发布。
项目中所使用的第三方组件遵循其各自的开源许可证，详见应用内 About 页面及 `Licenses` 目录。
