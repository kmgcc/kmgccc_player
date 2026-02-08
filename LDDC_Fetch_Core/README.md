# LDDC_Fetch_Core

把 LDDC 项目里“按歌名+歌手搜索并拉取歌词，再输出 LRC”的核心能力抽成一个**独立小包**，方便你在原生 macOS app 里以“子进程/本地服务”的形式嵌入。



## 功能

- 输入：`title` + `artist(可选)`
- 输出：LRC 文本
- 可选：
  - 翻译：无 / 使用平台自带翻译 
  - 逐行 / 逐字 / 增强格式（逐字）
  - 时间戳整体偏移 `offset_ms`
- 歌词源（可配置顺序）：`LRCLIB`、`QM`(QQ 音乐)、`KG`(酷狗)、`NE`(网易云)

## 运行环境

- Python `>= 3.10`
- 依赖：`httpx[http2,brotli]`、`pyaes`

## 安装（开发/本地）

在本目录下：

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -e .
```

> 你当前机器上如果 `python3` 是 3.9（会报语法不兼容），请安装/切换到 3.10+（例如 3.12）。

## 作为库调用（Python）

```py
from lddc_fetch_core import fetch_lrc
from lddc_fetch_core.models import Source

lrc = fetch_lrc(
    title="夜に駆ける",
    artist="YOASOBI",
    sources=(Source.LRCLIB, Source.QM, Source.KG, Source.NE),
    mode="verbatim",          # "line" / "verbatim" / "enhanced"
    translation="provider",   # "none" / "provider" / "openai" / "auto"
    offset_ms=0,
)
print(lrc)
```

## 一键测试并保存到文件（你要的这首歌）

在本目录下执行（需要能联网 + 已安装依赖）：

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -e .
python examples/fetch_save_song.py
```

输出文件：`examples/out/司南 - 守望者.lrc`

### OpenAI 翻译
do not use
<!-- ```py
lrc = fetch_lrc(
    title="夜に駆ける",
    artist="YOASOBI",
    translation="openai",
    openai_base_url="https://api.openai.com/v1",
    openai_api_key="YOUR_KEY",
    openai_model="gpt-4.1-mini",
    openai_target_lang="简体中文",
)
``` -->

## CLI（推荐用于 macOS app 嵌入）

安装后会有命令 `lddc-fetch`：

```bash
lddc-fetch --title "夜に駆ける" --artist "YOASOBI" --mode verbatim --translation provider
```

常用参数：
- `--mode`: `line|verbatim|enhanced`
- `--translation`: `none|provider|openai|auto`
- `--offset-ms`: 整体偏移（毫秒，可为负）
- `--sources`: 逗号分隔源顺序，如 `LRCLIB,QM,KG,NE`
- `--openai-*`: 仅当 `translation=openai/auto` 时需要

## 本地 HTTP 服务（可选）

启动：

```bash
python -m lddc_fetch_core.server --host 127.0.0.1 --port 8765
```

### 1. 合并获取 (Standard)

请求 URL: `/fetch`

```bash
curl -sS http://127.0.0.1:8765/fetch \
  -X POST -H 'content-type: application/json' \
  -d '{"title":"夜に駆ける","artist":"YOASOBI","mode":"verbatim","translation":"provider","offset_ms":0}'
```

返回：
```json
{"lrc":"[ti:...]\\n..."}
```

### 2. 分别获取 (Separate)

请求 URL: `/fetch_separate`

> 参数同上。此接口会返回两个独立的 LRC 内容：原文(`lrc_orig`)和翻译(`lrc_trans`)。

```bash
curl -sS http://127.0.0.1:8765/fetch_separate \
  -X POST -H 'content-type: application/json' \
  -d '{"title":"MALIYANG","artist":"珂拉琪 Collage","translation":"provider"}'
```

返回：
```json
{
  "lrc_orig": "[ti:MALIYANG]...", 
  "lrc_trans": "[ti:MALIYANG]..."
}
```

## 原生 macOS app 嵌入建议（Swift）

最稳妥的集成方式是**把它当成外部工具**：

### 方案 A：App 启动时拉起本地 HTTP 服务

1. App 启动 → `Process()` 启动 `python`（或你打包的可执行文件）运行 `lddc_fetch_core.server`
2. App 通过 `URLSession` POST 到 `http://127.0.0.1:<port>/fetch`
3. 拿到 `lrc` 字符串直接展示/保存

优点：接口稳定、便于扩展（未来加缓存/日志/限速）。

### 方案 B：每次查询直接跑 CLI

App 每次请求歌词时运行一次：

```bash
lddc-fetch --title ... --artist ... --mode ... --translation ...
```

读取 stdout 作为 LRC 输出；stderr 作为错误信息。

示例代码见：`examples/SwiftCallCLI.swift`。

### 打包 Python 运行时（你需要决定）

你后续可以选：
- 直接依赖用户机器上的 Python 3.10+（开发方便，但用户环境不可控）
- 把 Python + 依赖打进 `.app`（用户体验更好）
- 用 PyInstaller/Nuitka 把这部分打成单文件可执行（最便于随 app 分发）

## 目录结构

- `src/lddc_fetch_core/`：核心库
  - `fetch.py`：主入口 `fetch_lrc`
  - `providers/`：各歌词源实现
  - `parsers/`：lrc/qrc/krc/yrc 解析
  - `decryptor/`：qrc/krc/eapi 解密/加密
  - `translate/openai.py`：可选 OpenAI 翻译

## 2026-02-04 修复与注意事项

在集成和测试过程中，我们修复了以下问题以增强稳定性和兼容性：

1.  **依赖补全**：
    *   明确安装 `httpx[http2,brotli]` 和 `pyaes`。
    *   这些库对于某些音乐平台的解密和 HTTP/2 请求是必须的。

2.  **代码修复**：
    *   **KGProvider**: 修复了 `kg.py` 中使用了 `requests` 风格的 `.ok` 属性，替换为 `httpx` 的 `.is_success`。
    *   **Artist Model**: 修复了 `models.py` 中 `Artist` 类同时继承 `tuple` 并使用 `@dataclass` 导致的 Python 类型错误。
    *   **Fetch Logic**: 增强了 `fetch.py` 的容错性。现在单个歌词源（如网易云 NE）初始化失败（例如网络问题或反爬）**不会**导致整个搜索任务崩溃，而是会跳过该源继续尝试其他源。

3.  **建议**：
    *   如果遇到 `RuntimeError: ...` 类似关于 `asyncio` 或 `loop` 的错误，请确保你的 Python 环境是纯净的，且尽量不要混用 `async` 和同步调用。目前的实现是同步阻塞调用的（内部使用了 `httpx.Client` 而非 `AsyncClient`）。
    *   开发时请使用 Python 3.10+ 环境。
