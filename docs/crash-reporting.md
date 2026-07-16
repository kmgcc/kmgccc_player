# 崩溃报告与符号归档

崩溃报告是独立于匿名使用统计的诊断链路。PLCrashReporter 在崩溃现场只写入本地 pending report；
App 在下一次正常启动后导入、脱敏、持久化并按用户设置异步发送。MetricKit 的 crash、hang 和
CPU exception 诊断使用另一条持久化队列和 API，不会阻塞 PLCrashReporter 询问流程。

## Release 符号保留

生产 dSYM 默认不上传服务器。Release 构建必须同时提供两个不同的私有归档目录：

```bash
CRASH_SYMBOL_ARCHIVE_DIR='<本地私有归档目录>' \
CRASH_SYMBOL_BACKUP_DIR='<可靠备份目录>' \
./scripts/build_app.sh Release
```

构建会强制检查 App 主二进制与 dSYM 的 UUID 集合完全一致，生成
`kmgccc_player.symbols-manifest.json`，把包含 manifest 和完整 dSYM 的 ZIP 分别写入主归档与备份，
并验证两份归档 SHA-256 一致。两个目录不能相同；同名归档已存在但 manifest 不一致时构建失败，
避免覆盖另一个同 build 的符号文件。

`scripts/package-crash-symbols.sh` 也可以单独用于已有 App/dSYM：

```bash
./scripts/package-crash-symbols.sh \
  --app '<path>/kmgccc_player.app' \
  --dsym '<path>/kmgccc_player.app.dSYM' \
  --manifest '<path>/manifest.json' \
  --archive-dir '<主归档目录>' \
  --backup-dir '<备份目录>'
```

服务器默认只保存已经双层脱敏的原始报告，并显示“等待本地符号化”。管理者在服务端仓库运行本地
符号化命令：下载报告，按报告中的 Mach-O UUID 从上述归档选择 dSYM，使用 macOS `atos` 解析，
再按需上传只包含线程/帧位置、符号名和源文件 basename/行号的小型结果。服务端 dSYM 存储和自动
符号化是显式开关控制的可选能力。

## Debug 受控崩溃

Debug 构建支持环境变量 `KMGCCC_CRASH_TEST_MODE`，值为 `main-abort`、`background-abort` 或
`main-segv`。App 启动三秒后在指定线程触发信号。该入口不编译进 Release；测试完成后的下一次启动
必须移除环境变量，避免重复崩溃。
