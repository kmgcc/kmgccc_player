# LDDC Fetch Core

本目录保存播放器内置歌词服务的源码。它基于 [LDDC](https://github.com/chenmozhijin/LDDC) `84631e8cd011fcc3f71ca0ae017e2c9758958ffc` 提取，并加入本地 HTTP 服务与播放器所需的打包适配。App 运行时启动随包提供的 ARM64 onedir 产物，通过本地 HTTP 接口完成健康检查、歌词搜索和歌词获取；不依赖用户机器上的 Python 环境。

## 构建

默认使用 ARM64 Python 3.12：

```sh
./build_pyinstaller.sh
```

如 Python 位于其他位置：

```sh
LDDC_ARM_PYTHON=/path/to/arm64/python3 ./build_pyinstaller.sh
```

构建输出固定为：

```text
.build/products/lddc/
├── lddc-server
└── _internal/
```

主工程的 `Copy LDDC runtime` Build Phase 会将该目录复制到 App 的 `Contents/Resources/Tools/lddc-server/`。缺少可执行文件或 `_internal` 时，Xcode 构建直接失败。

日常构建统一从仓库根目录运行 `./scripts/bootstrap.sh`，无需单独调用本脚本。

## 源码入口

- `lddc_server_entry.py`：PyInstaller 入口。
- `src/lddc_fetch_core/server.py`：本地 HTTP 服务。
- `src/lddc_fetch_core/fetch.py`：歌词获取与来源调度。
- `src/lddc_fetch_core/providers/`：歌词来源实现。
- `src/lddc_fetch_core/parsers/`：歌词格式解析。
- `src/lddc_fetch_core/decryptor/`：歌词数据解密。

第三方许可见 `LICENSE`。
