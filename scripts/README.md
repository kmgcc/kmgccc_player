# 项目脚本

本目录下的脚本用于项目初始化、构建、验证、依赖维护和发布前检查。以下命令均从仓库根目录运行。

## 常用命令

**`bootstrap.sh`** — 准备所有外部构建依赖。

```sh
./scripts/bootstrap.sh                           # 完整准备
./scripts/bootstrap.sh --check                   # 仅校验，不下载不构建
./scripts/bootstrap.sh --check --component amll  # 检查单个组件
./scripts/bootstrap.sh --force --component lddc  # 强制重建单个组件
```

clone 之后首先运行此脚本。它会下载、构建并缓存五个外部组件（AMLL、LDDC、QQ Music Helper、MediaRemoteAdapter、SACAD），产物放在 `.build/products/` 下，由 Xcode Build Phase 复制进 App bundle。组件按源码 + 工具链哈希缓存，重新运行时会跳过未变更的组件。

**`verify.sh`** — 运行完整的 PR 前验证。

```sh
./scripts/verify.sh
```

依次执行 bootstrap、ARM64 无签名 Debug 构建、LRC 回归测试、XCTest 和 App bundle 组件检查。建议在提交 PR 前运行。输出写入临时目录，设置 `KMGCCC_KEEP_VERIFY_OUTPUT=1` 可保留。

**`build_and_run.sh`** — 构建 Debug 版 App 并启动。

```sh
./scripts/build_and_run.sh
CONFIGURATION=Release ./scripts/build_and_run.sh
```

以 `CODE_SIGNING_ALLOWED=NO` 构建，直接启动 App 二进制。`KMGCCC_LOG_LEVEL` 默认为 `info`。

**`build_app.sh`** — 构建不含本地运行时资源的独立 App bundle。

```sh
./scripts/build_app.sh Debug
./scripts/build_app.sh Release
```

产物输出到临时 DerivedData 目录，并验证 bundle 中不含运行时资源。可通过 `OUTPUT_DIR` 环境变量复制到指定目录。

## 依赖维护

**`sync-amll-from-fork.sh`** — 从 integration fork submodule 重新构建 AMLL bundle。

```sh
./scripts/sync-amll-from-fork.sh
```

从 `Dependencies/Submodules/AMLLIntegration/` 构建 AMLL core、lyric 和 background bundle，写入 `kmgccc_player/Resources/AMLL/`。在 fork 中修改 AMLL TypeScript 源码后运行。此脚本不会自动 commit，同步后应检查 submodule diff 并运行 `verify.sh`。

**`components/`** — 各外部组件的 bootstrap 子脚本（`amll.sh`、`lddc.sh`、`qqmusic-helper.sh`、`mediaremote.sh`、`sacad.sh`）。由 `bootstrap.sh` 引用，不应直接调用。

**`lib/common.sh`** — bootstrap 共享工具函数（日志、下载校验、stamp 管理、进程管理）。由 `bootstrap.sh` 引用，不应直接调用。

**`verify-amll-parser-shape.mjs`** — 比较新旧 AMLL 歌词解析器输出，检测回归。

```sh
OLD_AMLL_CORE=path/to/old-core.js node scripts/verify-amll-parser-shape.mjs
```

更新 AMLL submodule 时使用，确认新解析器输出兼容。需要旧版 `amll-core.js` 作为对比基线。

## 构建支持

**`prepare_runtime_resources.sh`** — Xcode Build Phase 脚本，将可选的本地运行时资源复制到 App bundle。

此脚本由 Xcode 在 Debug、Release 和 Archive 构建时自动调用，也用于命令行构建。行为由以下构建设置控制：

- `AUXILIARY_RESOURCE_MODE` — `auto`（默认）、`enabled` 或 `disabled`。
- `AUXILIARY_RESOURCE_ROOT` — 资源输入的本地路径。clean clone 上此变量为空，构建照常继续。
- `AUXILIARY_RESOURCE_STRICT` — 设为 `YES` 时，资源根目录配置错误会导致构建失败，而非跳过。

可选的本地构建输入通过 `Config/LocalOverrides.xcconfig` 配置。该文件在标准构建中不是必需的。

**`build_runtime_resources.sh`** — 命令行构建完整 App（含本地运行时资源）。

```sh
./scripts/build_runtime_resources.sh Debug
./scripts/build_runtime_resources.sh Release
```

强制启用资源，要求配置了 auxiliary resource root，并验证产物 bundle 包含预期的运行时 bundle。

**`check-app-bundle.sh`** — 验证 `.app` bundle 包含所有必需的组件。

```sh
./scripts/check-app-bundle.sh path/to/kmgccc_player.app
```

检查 App 可执行文件、AMLL WebView 资源、打包工具（LDDC server、QQMusic helper、SACAD）、MediaRemoteAdapter、本地化文件、许可证，以及禁止出现的条目（源码文件、README、测试文件、绝对路径）。

## 仓库维护

**`audit_release_contents.sh`** — 审计跟踪文件、Git 历史和 `.app` bundle 中的禁止内容。

```sh
./scripts/audit_release_contents.sh                           # 审计 HEAD
./scripts/audit_release_contents.sh --all-refs --reflogs     # 全面审计
./scripts/audit_release_contents.sh --app path/to/App.app    # 审计 bundle
```

检查范围：

- 不应出现在发布中的跟踪文件和工作树路径
- 可达 commit、ref 和 reflog 中的历史路径
- 不可达 Git 对象
- `.app` bundle 中的敏感文件类型

仅输出 commit/ref/路径元数据，不输出文件内容。退出状态 0 表示干净，1 表示发现禁止内容。

**`verify_repository_hygiene.sh`** — 跨所有 ref 和 reflog 运行严格仓库卫生检查。

```sh
./scripts/verify_repository_hygiene.sh
```

`audit_release_contents.sh --all-refs --reflogs` 的便捷包装。传入 `--ref` 可将审计限定到特定 ref。

## 脚本约定

- 从仓库根目录运行。各脚本自行解析自身位置。
- 生成产物放入 `.build/`（已 gitignore）。
- 使用 `set -euo pipefail`，遇错即停。
- `Config/LocalOverrides.xcconfig` 缺失是正常状态，构建在无可选本地输入时照常继续。
- `verify.sh` 是推荐的 PR 前入口。
- 维护脚本报告检查结果，不会自动推送、重写历史或修改工作树，除非命令明确说明且用户确认。
