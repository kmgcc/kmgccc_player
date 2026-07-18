# 项目脚本

以下命令均从仓库根目录运行。

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

在新的 DerivedData 中构建可由 clean clone 复现的 App，并执行 bundle 完整性检查。该入口显式禁用本机构建扩展。

用户协议和隐私政策位于受版本控制的 `kmgccc_player/LegalDocuments/`，属于公开且必需的运行资源；不要用本机忽略目录替代它们。

```sh
./scripts/build_app.sh Debug
./scripts/build_app.sh Release
```

可通过 `OUTPUT_DIR` 将最终 App 复制到指定目录。

### `verify.sh`

PR 前统一门禁：bootstrap、ARM64 无签名 Debug 构建、LRC 回归、XCTest 和 App bundle 检查。构建与测试阶段显式禁用本机构建扩展。

```sh
./scripts/verify.sh
```

失败日志写入临时目录；设置 `KMGCCC_KEEP_VERIFY_OUTPUT=1` 可保留成功产物。

### `check-app-bundle.sh`

检查 App 可执行文件、AMLL、外部 helper、MediaRemoteAdapter、本地化和许可证，并拒绝常见开发文件进入 bundle。

```sh
./scripts/check-app-bundle.sh /path/to/kmgccc_player.app
```

## Xcode 构建支持

### `run_build_extension.sh`

Xcode 的 `Run Optional Build Hook` Build Phase 调用此适配器。默认设置位于 `Config/Project.xcconfig`：

- `BUILD_EXTENSION_MODE`：`auto`（默认）、`enabled` 或 `disabled`。
- `BUILD_EXTENSION_HOOK`：可选的本机可执行文件路径。
- `BUILD_EXTENSION_STRICT`：`YES` 时，启用扩展但 hook 缺失或无输出会令构建失败。

本机需要扩展时，将 `Config/LocalOverrides.xcconfig.example` 复制为 `Config/LocalOverrides.xcconfig` 并设置 hook。Xcode 调用 hook 时传入 `--output <临时目录>`；hook 只应在该目录生成顶层输出。适配器成功后再更新 App resources，失败时保留上一轮完整输出；禁用或移除 hook 时会清除上一轮记录的扩展输出。

## 依赖维护

### `sync-amll-from-fork.sh`

从 `Dependencies/Submodules/AMLLIntegration/` 构建 AMLL bundle，并同步到 `kmgccc_player/Resources/AMLL/`。修改 fork 后运行此脚本，再执行完整歌词回归和 `verify.sh`。

`components/` 包含各组件 bootstrap 子脚本，`lib/common.sh` 提供共享函数；它们由 `bootstrap.sh` 调用，不应作为独立入口。

## 发布与仓库审计

```sh
./scripts/audit_release_contents.sh --all-refs --reflogs
./scripts/verify_repository_hygiene.sh
```

`audit_release_contents.sh` 检查跟踪路径、所选 Git 历史和可选 App bundle。准备推送或发布时，应在只含待发布 refs 的干净克隆中运行上面的命令；它不会把不随 refs 传输的本机不可达对象误算进发布范围。需要对当前本机对象库做取证时，额外传入 `--unreachable`；`verify_repository_hygiene.sh` 会先运行文本卫生检查，再自动包含该取证检查。

最终 App 中受控路径下的加密素材容器和编译后 Metal library 属于可分发运行产物；源码、明文素材、脚本，以及这些运行产物出现在公开工作树或 Git 历史中仍会阻断发布。它们不属于 `verify.sh` 的 PR 门禁。

公开发布按以下顺序收口：

1. 用已合并且通过 CI 的精确提交构建、审计并准备 Draft Release；Draft 只包含 DMG、`.symbols.zip` 和 `.sha256`。
2. 复核 Draft 的目标提交、资产 digest、签名说明和安装说明后，先发布 GitHub Release。
3. Release 已公开且 `/releases/latest` 指向新版本后，再通过独立 PR 更新 `pages/version.json`。不要让在线更新元数据提前指向仍处于 Draft 的版本。

## 约定

- 脚本从仓库根目录运行，并自行解析仓库路径。
- 构建产物放入已忽略的本地目录或临时目录。
- `Config/LocalOverrides.xcconfig` 是本机文件，不能提交。
- `verify.sh` 是合并前门禁，发布审计保持独立。
