# 外部组件与构建依赖

kmgccc_player 的 Swift 代码由 Xcode 构建，歌词渲染、歌词搜索、封面候选和系统播放状态读取还依赖若干独立运行组件。`scripts/bootstrap.sh` 统一取得、校验和构建这些组件，Xcode 只消费 bootstrap 生成的产品。

```mermaid
flowchart LR
    Sources["固定版本的源码或归档"] --> Bootstrap["scripts/bootstrap.sh"]
    Bootstrap --> Products["可复现的 arm64 产品"]
    Products --> Xcode["Xcode Build Phases"]
    Xcode --> App["App bundle"]
```

## 准备环境

```sh
./scripts/bootstrap.sh
```

首次运行会下载依赖并构建 Apple Silicon 产物，之后根据源码、工具链和架构状态复用缓存。CI 与本地开发使用同一入口，贡献者不需要手工寻找或替换二进制文件。

支持按组件检查或重建：

```sh
./scripts/bootstrap.sh --check
./scripts/bootstrap.sh --check --component amll
./scripts/bootstrap.sh --force --component amll
```

组件名为 `amll`、`lddc`、`qqmusic-helper`、`mediaremote` 和 `sacad`。

## 组件概览

| 组件 | 运行边界 | 用途 | 失败时的降级 |
| --- | --- | --- | --- |
| AMLL | WKWebView 中的 JavaScript 与 DOM | TTML 解析和逐词歌词渲染 | 对应歌词 surface 无法显示 |
| LDDC Fetch Core | 本机回环 HTTP 服务 | 多来源歌词搜索、获取和格式处理 | LDDC 搜索不可用，本地 AMLL DB 仍可用 |
| QQ Music Helper | stdin/stdout JSON 子进程 | QQ 音乐元数据和封面候选 | QQ 候选不可用，其他来源独立 |
| MediaRemoteAdapter | 原生 framework 与流式 JSON | 系统 Now Playing 状态和控制 | 系统外部播放不可用，本地与 Apple Music 独立 |
| SACAD | 单次命令行进程 | 专辑封面搜索和下载 | SACAD 候选不可用 |

这些组件都按进程或 WebView 边界隔离。Swift 侧只依赖稳定协议，不直接调用第三方服务内部 API。

## AMLL

[applemusic-like-lyrics](https://github.com/amll-dev/applemusic-like-lyrics) 提供逐词歌词渲染能力。项目使用固定 submodule 版本构建普通 DOM `LyricPlayer`、TTML parser 和背景渲染 bundle，App 通过 WKWebView 加载。

AMLL 资源分为两层：上游或集成层构建生成 JavaScript 与 CSS，App 适配层负责 bridge、surface 配置、时间预处理和原生状态投递。生成文件不作为手工编辑入口。

许可证：AGPL-3.0-only。宿主边界和时间算法见 [歌词渲染系统](lyric-rendering.md)。

## LDDC Fetch Core

[LDDC](https://github.com/chenmozhijin/LDDC) 的无界面 fetch core 被封装为本机 HTTP 服务，由 `LDDCServerManager` 按需启动。服务提供健康检查、搜索和歌词格式处理，Swift 不需要嵌入 Python 解释器 API。

bootstrap 使用 ARM64 Python 与 PyInstaller 生成 onedir 产品。运行时只使用 App bundle 中的服务，不依赖系统 Python 或开发目录。

许可证：GPL-3.0-only。

## QQ Music Helper

QQ Music Helper 将 [QQMusicApi](https://github.com/L-1124/QQMusicApi) 包装为逐行 JSON 子进程。App 每行写入一个请求，helper 每行返回一个 JSON 响应；诊断信息写入 stderr，保证 stdout 始终可由程序解析。

查询结果只是候选，仍须进入共享封面或元数据管线。Swift 不直接调用 QQ Music API，也不让 helper 绕过资料库持久化边界。

许可证：QQMusicApi 为 GPL-3.0-or-later，包装层随主仓库许可证。

## MediaRemoteAdapter

[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) 负责读取 macOS 系统正在播放的外部媒体状态，并提供当前可用的控制能力。`SystemNowPlayingProvider` 消费它的流式 JSON，维护连接状态、稳定曲目和进度基线。

bootstrap 从固定源码构建 Apple Silicon framework 与 client，避免提交或信任来源不明的预编译 framework。

许可证：BSD-3-Clause。

## SACAD

[SACAD](https://github.com/desbma/sacad) 按歌手、专辑和尺寸搜索封面。App 通过 `CoverDownloadService` 调用命令行程序，结果进入共享候选管线，SACAD 不直接修改资料库。

bootstrap 使用固定的 macOS ARM64 预编译产物并校验归档，不在本地重复编译。

许可证：MPL-2.0。

## Swift Package

工程通过 Swift Package Manager 使用 [WhatsNewKit](https://github.com/SvenTiigi/WhatsNewKit)，由 Xcode 根据已固定的 package resolution 解析。它属于编译期依赖，不进入 bootstrap 的外部进程构建链。

## 可复现构建

bootstrap 把下载、源码、中间工作目录、最终产品和日志分开保存。Xcode 只复制最终产品，不从下载缓存、虚拟环境或构建中间目录取文件。

组件检查会验证固定版本、校验值、工具链状态、产品结构和 `arm64` 架构。App 运行时只从 `Bundle.main.resourceURL` 解析组件，不扫描仓库路径，不退回系统解释器，也不依赖环境变量寻找替代文件。

这条边界保证干净 clone、CI 和日常开发使用相同产品布局，也让单个组件失败时能够沿表中的方式独立降级。

## 许可证

第三方许可证文本随 App 一同提供：

| 组件 | 许可证 |
| --- | --- |
| AMLL | AGPL-3.0-only |
| LDDC Fetch Core | GPL-3.0-only |
| QQMusicApi | GPL-3.0-or-later |
| MediaRemoteAdapter | BSD-3-Clause |
| SACAD | MPL-2.0 |
