# 外部组件与构建依赖

kmgccc_player 的 Swift 代码由 Xcode 直接构建，但歌词渲染、在线搜索、封面查询和外部播放状态读取这些能力依赖前端资源、Python 服务或原生 framework。这些外部组件不会被提交到 Xcode 工程内部，而是由 `scripts/bootstrap.sh` 统一取得和构建，产物放在 `.build/products/` 下，再由 Xcode 的 Build Phase 复制进 App bundle。

只要环境满足要求，`bootstrap.sh` 会处理所有外部组件的获取、校验、编译和缓存，贡献者不需要手工下载任何二进制文件。

## 一键准备

```sh
./scripts/bootstrap.sh
```

首次运行会下载依赖并编译所有 ARM64 产物，耗时较长。之后每次运行会比较源码、架构和工具链，未变化的组件直接复用缓存。CI 和新环境都应从此命令开始。

## 组件概览

| 组件 | 用途 | 来源方式 | 修改 |
| --- | --- | --- | --- |
| AMLL | 歌词渲染 | Git submodule（项目 fork） | 有 |
| LDDC Fetch Core | 歌词搜索 | 主仓库版本化源码 | 有 |
| QQ Music Helper | QQ 音乐封面查询 | 固定 PyPI 版本 + 包装层 | 有 |
| MediaRemoteAdapter | 系统播放状态 | 固定源码归档下载 | 有（补丁） |
| SACAD | 封面搜索 | 固定二进制下载 | 无 |

## AMLL

AMLL（applemusic-like-lyrics）是歌词渲染引擎，App 在 WKWebView 中加载它的 DOM LyricPlayer 来渲染逐词歌词。

**关键约束：项目使用的不是 AMLL 官方仓库的最新源码。** 项目维护了一个独立的 integration fork：[kmgcc/applemusic-like-lyrics-kmgcccplayer-integration](https://github.com/kmgcc/applemusic-like-lyrics-kmgcccplayer-integration)，主仓库通过 Git submodule 将它固定在 `Dependencies/Submodules/AMLLIntegration/`，指向一个经过完整歌词显示回归验证的 commit（当前为 `91939107e9ec338c20c5a6a672e4d894868ecf2f`）。

这个 fork 包含播放器集成所必需的行为调整：浏览器 bundle 入口、少量无法放在适配层的 renderer patch，以及构建配置。主仓库还维护了 `index.html`、`bridge.js`、样式和 timing 预处理来适配 App 的 WebView 环境，这些属于 App 层代码，不属于 AMLL 核心。

**不要做这几件事：**

- 不要将 submodule 改为指向 AMLL 官方 main 分支；
- 不要随意更新 submodule 的 commit；
- 不要手工修改 `kmgccc_player/Resources/AMLL/` 下的 `amll-core.js`、`amll-lyric.js`、`amll-background.js` 和 `style.css`——它们是生成文件，任何改动都会在下次构建时被覆盖。

**更新 AMLL commit 的正确流程：** 在 fork 仓库中修改 TypeScript 源码，构建后运行 `scripts/sync-amll-from-fork.sh` 同步生成文件到 App 的 Resources 目录，然后通过完整歌词回归验证（窗口歌词、全屏、cover blur、seek、暂停、重叠行和 lead-in），最后同时提交 fork 和主仓库的变更。

`bootstrap.sh` 使用 Node.js 22 和 pnpm 11.1.0 构建。产物包括 `.build/products/amll/` 下的四个文件，这些文件也会同步到 `kmgccc_player/Resources/AMLL/` 供 Xcode 打包。

许可证：AGPL-3.0-only。

## LDDC Fetch Core

LDDC Fetch Core 是基于 [LDDC](https://github.com/chenmozhijin/LDDC)（commit `84631e8cd011fcc3f71ca0ae017e2c9758958ffc`，对应上游 v0.9.2）修改的歌词搜索服务。源码随主仓库版本化在 `Dependencies/Sources/LDDCFetchCore/` 下。

仓库从上游提取了无 GUI 的 fetch core，增加了本地 HTTP 服务、播放器需要的数据模型和 PyInstaller 打包入口（本地包版本 0.1.0）。App 运行时通过 `LDDCServerManager` 启动服务，在 `127.0.0.1` 随机端口上提供 `/health`、`/search` 等接口，供歌词搜索管线使用。搜索失败时，AMLL DB 本地索引仍是独立来源，不会完全阻断歌词功能。

`bootstrap.sh` 使用 ARM64 Python 3.12 和 PyInstaller 6.21.0 构建，产物为 `.build/products/lddc/` 下的 onedir 可执行程序。贡献者不需要手工运行 Python 服务。

许可证：GPL-3.0-only。

## QQ Music Helper

QQ Music Helper 是 QQ 音乐元数据和封面候选的查询工具。`Tools/QQMusicHelper/` 保存的是本项目自己的通信包装层（`main.py`），负责 stdio JSON 协议：App 通过 `QQMusicHelperProcess` 以子进程方式启动 helper，逐行发送 JSON 请求，读取 JSON 响应，所有诊断信息走 stderr。实际使用的 QQMusicApi 库通过 `qqmusic-api-python==0.5.3` 固定版本安装。

`bootstrap.sh` 使用 ARM64 Python 3.12 和 PyInstaller 6.21.0 将包装层和依赖打包成独立的 ARM64 可执行文件，产物为 `.build/products/qqmusic-helper/`。Xcode 的 Build Phase 将其复制到 App bundle 的 `Contents/Resources/Tools/qqmusic-helper/`。helper 从 bundle 路径启动；不可用时 QQ 音乐候选查询失败，其他封面来源仍由共享管线决定。

许可证：QQMusicApi 为 GPL-3.0-or-later；包装层随主仓库 AGPL-3.0。

## MediaRemoteAdapter

MediaRemoteAdapter 负责读取 macOS 系统正在播放的外部媒体状态，并提供可用的播放控制。运行时由 `SystemNowPlayingProvider` 使用 bundle 内 Perl launcher、framework 和 test client 建立连接。

`bootstrap.sh` 下载 [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) 的固定 commit `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a` 源码归档（SHA-256: `111e285e7a8acfb05b7339883e303a360f8a7a9b7acb4f0f5c01b647deb8ceb5`），不提交预编译 framework。项目保留了一个版本化补丁 `Tools/MediaRemoteAdapter/unbuffered-output.patch`，它只在 Perl stdout 上开启 autoflush（`$| = 1`），避免流式 JSON 输出被缓冲，不改变任何业务逻辑。bootstrap 会先应用补丁，再用 CMake 生成 Xcode 工程，以 Release、ARM64、无签名方式构建，产物为 `.build/products/mediaremote/`。

许可证：BSD-3-Clause。

## SACAD

SACAD 用于按 artist、album 和尺寸参数搜索并下载专辑封面。`bootstrap.sh` 下载 [desbma/sacad](https://github.com/desbma/sacad) 的 release 3.0.1 macOS ARM64 归档（SHA-256: `6d0fe6e1f3e494be88a7a3fcf6ae88c998c3c70194d2b4b3749c7fc150c162f7`），校验后直接使用上游二进制，不本地编译。产物为 `.build/products/sacad/sacad`。

App 通过 `CoverDownloadService` 以子进程方式调用 SACAD，搜索结果进入共享封面候选管线，SACAD 不直接写曲库。SACAD 失败时，QQ Music Helper 和本地缓存等其他来源不受影响。

许可证：MPL-2.0。

## Swift Package 依赖

工程通过 Swift Package Manager 固定使用 [WhatsNewKit](https://github.com/SvenTiigi/WhatsNewKit) 2.2.1，由 Xcode 自动解析，不属于 bootstrap 管理的外部可执行组件。

## 缓存和构建产物

bootstrap 的目录结构：

| 目录 | 内容 |
| --- | --- |
| `.build/downloads/` | 已校验的下载归档 |
| `.build/sources/` | 展开的第三方源码 |
| `.build/work/` | 虚拟环境、CMake 和 PyInstaller 中间文件 |
| `.build/products/` | Xcode 复制外部组件的唯一产物根目录 |
| `.build/logs/` | 构建日志 |

AMLL 稍有不同：生成文件先进入 `.build/products/amll/`，再同步到 `kmgccc_player/Resources/AMLL/`，Xcode 随整个 `AMLL` 文件夹复制。

## 单独重建

```sh
./scripts/bootstrap.sh --check --component mediaremote    # 检查单个组件
./scripts/bootstrap.sh --force --component mediaremote   # 强制重建
./scripts/bootstrap.sh --check                            # 全部检查（不下载不构建）
```

组件名：`amll`、`lddc`、`qqmusic-helper`、`mediaremote`、`sacad`。

## 常见问题

**构建失败，日志在哪里？** 查看 `.build/logs/` 目录。每个组件有独立的日志文件。

**为什么 bootstrap 说产物 stale？** 源码、构建脚本、工具链版本或架构发生了变化。用 `--force --component <name>` 强制重建。

**可以不用 bootstrap 手动准备这些组件吗？** 技术上可以，但 CI 和 `verify.sh` 都依赖 bootstrap 确保产物版本一致。手动替换的二进制可能通过不了 stamp 校验。

## 许可证

各组件的许可证文本随 App 打包在 `Contents/Resources/Licenses/` 下：

| 组件 | 许可证 |
| --- | --- |
| AMLL | AGPL-3.0-only |
| LDDC Fetch Core | GPL-3.0-only |
| QQMusicApi | GPL-3.0-or-later |
| MediaRemoteAdapter | BSD-3-Clause |
| SACAD | MPL-2.0 |
