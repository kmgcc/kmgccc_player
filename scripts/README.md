# 项目脚本

以下命令均从仓库根目录运行。

常规改动的构建和测试由维护者显式运行。符合仓库重大工程变更标准时，Agent 可在实现全部完成后做一次最终 Debug build-only 编译，并只为修复编译错误再次 build；该例外不包括测试、启动 App、`build_and_run.sh`、`verify.sh` 或 Release 构建。其余编译和测试须用户在当前任务明确要求。

## 常用入口

### `bootstrap.sh`

准备 App 需要的五个外部运行组件，产物写入 `.build/products/`，由 Xcode Build Phase 复制进 App bundle。

```sh
./scripts/bootstrap.sh
./scripts/bootstrap.sh --check
./scripts/bootstrap.sh --check --component amll
./scripts/bootstrap.sh --force --component lddc
```

### `build_and_run.sh`

构建并启动 App，默认使用 Debug：

```sh
./scripts/build_and_run.sh
CONFIGURATION=Release ./scripts/build_and_run.sh
```

标准本机构建会读取可选的 `Config/LocalOverrides.xcconfig`。

### `build_app.sh`

构建 App 并执行 bundle 完整性检查，默认保留 DerivedData 缓存。该入口显式禁用本机构建扩展；需要全新构建时使用 `CLEAN_BUILD=1`，也可通过 `DERIVED_DATA_PATH` 指定独立目录。
构建前后都会检查 MelismaKit 的依赖来源，默认 `MELISMAKIT_EXPECTED_SOURCE=auto`，按 Xcode 工程配置接受本地或远程依赖。

用户协议和隐私政策位于受版本控制的 `kmgccc_player/LegalDocuments/`，属于公开且必需的运行资源；不要用本机忽略目录替代它们。

```sh
./scripts/build_app.sh Debug
./scripts/build_app.sh Release
CLEAN_BUILD=1 ./scripts/build_app.sh Release
```

要生成 Developer ID 发行签名 App，显式提供本机签名身份；脚本会把这些参数传给
`xcodebuild`，避免 Release 配置中的开发签名默认值被误用：

```sh
CODE_SIGNING_ALLOWED=YES \
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
CODE_SIGN_STYLE=Manual \
DEVELOPMENT_TEAM=TEAMID \
CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
OUTPUT_DIR=/tmp/kmgccc-player-release \
./scripts/build_app.sh Release
```

这一步只负责生成并检查签名 App；公证、staple、Gatekeeper 和实际安装启动仍是独立的发布验收门禁。

可通过 `OUTPUT_DIR` 将最终 App 复制到指定目录。

### `verify.sh`

手动运行的完整门禁包括 bootstrap、动效与 UI 静态检查、ARM64 无签名 Debug 构建、独立回归、串行 XCTest 和 App bundle 检查。独立回归覆盖 LRC、CostBoundedCache、封面缓存 generation、设备遥测和资料库规范化。构建与测试阶段显式禁用本机构建扩展。仓库不设 GitHub macOS CI，push 与 PR 不触发远端编译；该门禁由维护者在本机运行。
它按 Xcode 工程配置检查 MelismaKit 来源，默认接受本地和远程依赖。

```sh
./scripts/verify.sh
```

失败日志写入临时目录；设置 `KMGCCC_KEEP_VERIFY_OUTPUT=1` 可保留成功产物。

### `check-app-bundle.sh`

检查 App 可执行文件、AMLL、外部 helper、MediaRemoteAdapter、本地化和许可证，并拒绝常见开发文件进入 bundle。

```sh
./scripts/check-app-bundle.sh /path/to/kmgccc_player.app
```

### check-app-process-state.sh

默认只读检查当前是否已有 kmgccc_player 进程，并输出 PID、父进程、启动时间和实际命令路径。
发现进程时返回失败码。传入 --terminate-existing 后，只处理精确匹配的 kmgccc_player 进程：
先发送 TERM，等待退出，必要时发送 KILL。

    ./scripts/check-app-process-state.sh
    ./scripts/check-app-process-state.sh --terminate-existing

### check-melismakit-dependency.sh

检查 App 的 Swift Package 依赖来源和构建日志。默认跟随 Xcode 工程配置，接受本地或远程 MelismaKit。远程版本由工程的版本约束和 `Package.resolved` 管理，缺少 pin 时交由 Xcode 在构建期间解析。

```sh
./scripts/check-melismakit-dependency.sh
./scripts/check-melismakit-dependency.sh --build-log /path/to/xcodebuild.log
./scripts/check-melismakit-dependency.sh --require-local
./scripts/check-melismakit-dependency.sh --require-remote
```

`build_and_run.sh`、`build_app.sh` 和 `verify.sh` 默认使用 `MELISMAKIT_EXPECTED_SOURCE=auto`。日志缺少组件源码路径时仅提示，适用于复用组件缓存的增量构建。发现来源冲突时阻塞。

当前任务直接修改本地组件时，使用 `MELISMAKIT_EXPECTED_SOURCE=local` 并确认实际编译输入采用这次组件修改。需要限定远程来源时可设置 `MELISMAKIT_EXPECTED_SOURCE=remote`。

### check-ui-consistency.sh

检查本次新增或修改的 SwiftUI/AppKit UI 代码是否引入已知的局部样式漂移。默认只检查变更
行和未跟踪的新文件，不会把历史遗留问题混入当前任务；--all 用于一次性审计指定 UI
目录。涉及新增用户文案时使用 --strict-copy，把明显的反向解释交给门禁处理。

运行方式：

    ./scripts/check-ui-consistency.sh
    ./scripts/check-ui-consistency.sh --strict-copy
    ./scripts/check-ui-consistency.sh --all

## Xcode 构建支持

### `run_build_extension.sh`

Xcode 的 `Run Optional Build Hook` Build Phase 调用此适配器。默认设置位于 `Config/Project.xcconfig`：

- `BUILD_EXTENSION_MODE`：`auto`（默认）、`enabled` 或 `disabled`。
- `BUILD_EXTENSION_HOOK`：可选的本机可执行文件路径。
- `BUILD_EXTENSION_STRICT`：`YES` 时，启用扩展但 hook 缺失或无输出会令构建失败。

本机需要扩展时，将 `Config/LocalOverrides.xcconfig.example` 复制为 `Config/LocalOverrides.xcconfig` 并设置 hook。Xcode 调用 hook 时传入 `--output <临时目录>`；hook 只应在该目录生成顶层输出。适配器成功后再更新 App resources，失败时保留上一轮完整输出；禁用或移除 hook 时会清除上一轮记录的扩展输出。

## 依赖维护

### `sync-amll-from-fork.sh`

从 `Dependencies/Submodules/AMLLIntegration/` 只构建网格背景 bundle，并同步 `amll-background.js` 到 `kmgccc_player/Resources/AMLL/`。修改 fork 后运行此脚本，再检查网格背景资源和匹配的 Debug Build。

`components/` 包含各组件 bootstrap 子脚本，`lib/common.sh` 提供共享函数；它们由 `bootstrap.sh` 调用，不应作为独立入口。

## 发布与仓库审计

```sh
./scripts/verify_textual_hygiene.sh
FROZEN_SHA="$(git rev-parse HEAD)"
./scripts/audit_release_contents.sh --ref origin/main --ref "$FROZEN_SHA" --reflogs
```

`audit_release_contents.sh` 检查跟踪路径、所选 Git 历史和可选 App bundle。准备推送或发布时，应在只含待发布 refs 的干净克隆中运行上面的命令；它不会把不随 refs 传输的本机不可达对象误算进发布范围。需要对当前本机对象库做取证时，才额外传入 `--unreachable`；`verify_repository_hygiene.sh` 是包含所有本机 refs 和不可达对象的全面取证入口，不是发布线的默认命令。

最终 App 中受控路径下的加密素材容器和编译后 Metal library 属于可分发运行产物；源码、明文素材、脚本，以及这些运行产物出现在公开工作树或 Git 历史中仍会阻断发布。它们不属于 `verify.sh` 的 PR 门禁。

公开发布按以下顺序收口：

1. 用已合并且通过 CI 的精确提交构建、审计并准备 Draft Release；Draft 只包含 DMG、`.symbols.zip` 和 `.sha256`。
2. 复核 Draft 的目标提交、资产 digest、签名说明和安装说明后，先发布 GitHub Release。
3. Release 已公开且 `/releases/latest` 指向新版本后，再通过独立 PR 更新 `pages/version.json`。不要让在线更新元数据提前指向仍处于 Draft 的版本。

## 约定

- 脚本从仓库根目录运行，并自行解析仓库路径。
- 构建产物放入已忽略的本地目录或临时目录。
- `Config/LocalOverrides.xcconfig` 是本机文件，不能提交。
- `verify.sh` 是由维护者显式运行的合并前门禁；重大工程变更的最终编译许可不包含它，Agent 仅在用户于当前任务明确要求时运行。发布审计保持独立。
