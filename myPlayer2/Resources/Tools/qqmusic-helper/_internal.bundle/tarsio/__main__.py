"""Tarsio CLI - Tars 编解码命令行工具."""

from __future__ import annotations

import json
import mmap
import string
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import click as click_module
    from rich.console import Console as ConsoleType
    from rich.tree import Tree as TreeType
else:
    try:
        import click as click_module
        from rich.console import Console as ConsoleType
        from rich.tree import Tree as TreeType
    except ImportError:
        click_module = None
        ConsoleType = None
        TreeType = None

from tarsio._core import TraceNode, decode_raw, decode_trace, probe_struct

click = click_module


@dataclass(slots=True)
class ProbePolicy:
    """深度探测策略配置."""

    mode: str
    max_bytes: int
    max_depth: int
    max_nodes: int


@dataclass(slots=True)
class ProbeRuntime:
    """一次 CLI 执行的探测运行时状态."""

    probed_nodes: int = 0
    probe_cache: dict[bytes, Any | None] = field(default_factory=dict)
    trace_cache: dict[bytes, TraceNode] = field(default_factory=dict)


@dataclass(slots=True)
class InputBuffer:
    """输入缓冲区与其资源句柄."""

    data: bytes | memoryview
    mm: mmap.mmap | None = None
    view: memoryview | None = None

    def close(self) -> None:
        """释放输入资源."""
        if self.view is not None:
            self.view.release()
            self.view = None
        if self.mm is not None:
            self.mm.close()
            self.mm = None


def _check_cli_deps() -> None:
    """检查 CLI 依赖是否安装."""
    if not click:
        print(
            "错误: CLI 依赖未安装\n请运行: pip install tarsio[cli]",
            file=sys.stderr,
        )
        sys.exit(1)


def parse_hex_string(hex_str: str) -> bytes:
    """解析 hex 字符串为字节.

    Args:
        hex_str: hex 编码字符串.

    Returns:
        解析后的字节数据.
    """
    cleaned = hex_str.strip()
    if cleaned.lower().startswith("0x"):
        cleaned = cleaned[2:]
    return bytes.fromhex(cleaned)


def _parse_hex_stream(path: Path, chunk_size: int = 65536) -> bytes:
    """流式解析 hex 文本文件.

    Args:
        path: hex 文本文件路径.
        chunk_size: 单次读取字符数.

    Returns:
        解析后的字节数据.

    Raises:
        UnicodeDecodeError: 文件不是 UTF-8 文本.
        ValueError: 文件内容不是合法 hex.
        OSError: 文件读取失败.
    """
    hex_digits = set(string.hexdigits)
    output = bytearray()
    pending: str | None = None
    saw_digit = False
    pending_prefix_zero = False
    pending_prefix_pos = -1
    index = 0

    def push_hex(ch: str, pos: int) -> None:
        nonlocal pending, saw_digit
        if ch not in hex_digits:
            raise ValueError(f"第 {pos} 位包含非法 hex 字符: {ch!r}")
        saw_digit = True
        if pending is None:
            pending = ch
        else:
            output.append(int(f"{pending}{ch}", 16))
            pending = None

    with path.open("r", encoding="utf-8") as f:
        for chunk in iter(lambda: f.read(chunk_size), ""):
            for ch in chunk:
                if pending_prefix_zero:
                    if ch in ("x", "X"):
                        pending_prefix_zero = False
                        index += 1
                        continue
                    push_hex("0", pending_prefix_pos)
                    pending_prefix_zero = False

                if ch.isspace():
                    index += 1
                    continue

                if not saw_digit and pending is None and ch == "0":
                    pending_prefix_zero = True
                    pending_prefix_pos = index
                    index += 1
                    continue

                push_hex(ch, index)
                index += 1

    if pending_prefix_zero:
        push_hex("0", pending_prefix_pos)

    if not saw_digit:
        raise ValueError("hex 输入为空")
    if pending is not None:
        raise ValueError("hex 输入长度必须为偶数")
    return bytes(output)


def _validate_input_args(encoded: str | None, file: Path | None) -> None:
    """校验输入参数互斥关系."""
    if encoded is None and file is None:
        raise ValueError("必须提供 ENCODED 参数或 --file 选项")
    if encoded is not None and file is not None:
        raise ValueError("不能同时使用 ENCODED 参数和 --file 选项")


def _read_input(
    encoded: str | None,
    file: Path | None,
    file_format: str,
) -> InputBuffer:
    """读取 CLI 输入并返回缓冲对象."""
    if file is None:
        assert encoded is not None
        return InputBuffer(data=parse_hex_string(encoded))

    if file_format == "hex":
        return InputBuffer(data=_parse_hex_stream(file))

    if file.stat().st_size == 0:
        return InputBuffer(data=b"")

    with file.open("rb") as f:
        mm = mmap.mmap(f.fileno(), length=0, access=mmap.ACCESS_READ)
    view = memoryview(mm)
    return InputBuffer(data=view, mm=mm, view=view)


def _decode_payload(data: bytes | memoryview, fmt: str) -> Any:
    """按输出模式执行解码."""
    if fmt == "tree":
        if isinstance(data, memoryview):
            return decode_trace(data.tobytes())
        return decode_trace(data)
    return decode_raw(data)


def _allow_probe(
    payload: bytes, depth: int, policy: ProbePolicy, rt: ProbeRuntime
) -> bool:
    """根据策略判断是否允许探测."""
    if policy.mode == "off":
        return False
    if rt.probed_nodes >= policy.max_nodes:
        return False
    if depth > policy.max_depth:
        return False
    if policy.mode == "auto" and len(payload) > policy.max_bytes:
        return False
    rt.probed_nodes += 1
    return True


def _probe_bytes(
    payload: bytes, depth: int, policy: ProbePolicy, rt: ProbeRuntime
) -> Any | None:
    """带缓存地探测 bytes 是否可解释为 Struct."""
    if payload in rt.probe_cache:
        return rt.probe_cache[payload]
    if not _allow_probe(payload, depth, policy, rt):
        rt.probe_cache[payload] = None
        return None
    result = probe_struct(payload)
    rt.probe_cache[payload] = result
    return result


def _allow_trace_probe(
    payload: bytes, depth: int, policy: ProbePolicy, rt: ProbeRuntime
) -> bool:
    """根据策略判断是否允许 trace 探测."""
    cache_hit = payload in rt.trace_cache
    if cache_hit:
        return True
    return _allow_probe(payload, depth, policy, rt)


def _decode_trace_cached(payload: bytes, rt: ProbeRuntime) -> TraceNode:
    """带缓存地执行 decode_trace."""
    if payload in rt.trace_cache:
        return rt.trace_cache[payload]
    trace = decode_trace(payload)
    rt.trace_cache[payload] = trace
    return trace


def deep_probe(data: Any, policy: ProbePolicy, rt: ProbeRuntime, depth: int = 0) -> Any:
    """递归探测并解码 bytes 中的 Struct."""
    if isinstance(data, dict):
        return {k: deep_probe(v, policy, rt, depth + 1) for k, v in data.items()}
    if isinstance(data, list):
        return [deep_probe(item, policy, rt, depth + 1) for item in data]
    if isinstance(data, bytes):
        struct = _probe_bytes(data, depth, policy, rt)
        if struct:
            return deep_probe(struct, policy, rt, depth + 1)
        return data
    return data


def build_trace_tree(
    node: TraceNode,
    policy: ProbePolicy,
    rt: ProbeRuntime,
    parent: TreeType | None = None,
    depth: int = 0,
) -> TreeType:
    """基于 TraceNode 构建 rich Tree."""
    from rich.text import Text
    from rich.tree import Tree

    label = Text()

    if node.jce_type != "ROOT":
        label.append(f"Tag {node.tag} ", style="bold blue")

    type_desc = node.jce_type
    if node.type_name:
        type_desc = f"{node.type_name}"
    label.append(f"({type_desc})", style="cyan")

    if node.name:
        label.append(f" [{node.name}]", style="yellow")

    if node.value is not None:
        val_str = str(node.value)
        if isinstance(node.value, str):
            val_str = repr(node.value)
        elif isinstance(node.value, bytes):
            preview = node.value[:16].hex().upper()
            if len(node.value) > 16:
                val_str = f"<{len(node.value)} bytes> {preview}..."
            else:
                val_str = f"<{len(node.value)} bytes> {preview}"
        label.append(": ", style="white")
        label.append(val_str, style="green")

    tree = Tree(label) if parent is None else parent.add(label)

    for child in node.children:
        build_trace_tree(child, policy, rt, tree, depth + 1)

    if node.jce_type == "SimpleList" and isinstance(node.value, bytes):
        if not _allow_trace_probe(node.value, depth, policy, rt):
            return tree
        try:
            inner_trace = _decode_trace_cached(node.value, rt)
        except Exception:
            inner_trace = None
        if inner_trace is not None and inner_trace.children:
            inner_branch = tree.add(
                Text(">>> Probed Structure >>>", style="bold magenta")
            )
            for child in inner_trace.children:
                build_trace_tree(child, policy, rt, inner_branch, depth + 1)
            return tree

    return tree


class BytesEncoder(json.JSONEncoder):
    """自定义 JSON encoder, 处理 bytes."""

    def default(self, o: Any) -> Any:
        """将 bytes 转换为可序列化格式."""
        if isinstance(o, bytes):
            try:
                return o.decode("utf-8")
            except UnicodeDecodeError:
                return f"0x{o.hex()}"
        return super().default(o)


def _prepare_dict_data(data: Any, policy: ProbePolicy, rt: ProbeRuntime) -> Any:
    """将解码结果转为纯 dict 结构以供输出."""
    output_data = data
    if hasattr(data, "to_dict"):
        output_data = data.to_dict()

    if isinstance(output_data, dict):
        output_data = deep_probe(output_data, policy, rt)
    return output_data


def format_output(
    data: Any,
    fmt: str,
    console: ConsoleType,
    policy: ProbePolicy,
    rt: ProbeRuntime,
) -> None:
    """格式化输出数据."""
    if fmt == "json":
        output_data = _prepare_dict_data(data, policy, rt)
        json_str = json.dumps(
            output_data,
            cls=BytesEncoder,
            indent=2,
            ensure_ascii=False,
        )
        from rich.syntax import Syntax

        syntax = Syntax(
            json_str,
            "json",
            theme="ansi_dark",
            background_color="default",
            word_wrap=True,
        )
        console.print(syntax)
        return

    if fmt == "tree":
        if not isinstance(data, TraceNode):
            console.print("[red]Internal Error: Tree format requires TraceNode[/]")
            return
        tree = build_trace_tree(data, policy, rt)
        console.print(tree)
        return

    output_data = _prepare_dict_data(data, policy, rt)
    console.print(output_data)


def _render_or_dump(
    decoded: Any,
    fmt: str,
    output: Path | None,
    console: ConsoleType,
    error_console: ConsoleType,
    policy: ProbePolicy,
    rt: ProbeRuntime,
) -> None:
    """渲染终端输出或写入文件."""
    if output is None:
        format_output(decoded, fmt, console, policy, rt)
        return

    try:
        save_data = _prepare_dict_data(decoded, policy, rt)
        with output.open("w", encoding="utf-8") as f:
            json.dump(
                save_data,
                f,
                cls=BytesEncoder,
                indent=2,
                ensure_ascii=False,
            )
    except (OSError, TypeError) as e:
        error_console.print(f"[red]Error:[/] 输出失败: {e}")
        raise SystemExit(1) from e
    console.print(f"[green]输出已保存到:[/] {output}")


def _create_cli() -> Any:
    """创建 CLI 命令."""
    _check_cli_deps()

    from rich.console import Console

    console = Console()
    error_console = Console(stderr=True)

    @click.command()
    @click.argument("encoded", required=False)
    @click.option(
        "-f",
        "--file",
        type=click.Path(exists=True, path_type=Path),
        help="从文件读取输入数据",
    )
    @click.option(
        "--file-format",
        type=click.Choice(["bin", "hex"]),
        default="bin",
        show_default=True,
        help="文件输入格式: bin 表示原始二进制, hex 表示十六进制文本",
    )
    @click.option(
        "--probe",
        type=click.Choice(["off", "auto", "on"]),
        default="auto",
        show_default=True,
        help="嵌套 bytes 探测策略",
    )
    @click.option(
        "--probe-max-bytes",
        type=click.IntRange(min=1),
        default=65536,
        show_default=True,
        help="probe=auto 时单个 bytes 允许探测的最大长度",
    )
    @click.option(
        "--probe-max-depth",
        type=click.IntRange(min=0),
        default=3,
        show_default=True,
        help="最大探测递归深度",
    )
    @click.option(
        "--probe-max-nodes",
        type=click.IntRange(min=1),
        default=256,
        show_default=True,
        help="单次执行最多探测的 bytes 节点数量",
    )
    @click.option(
        "--format",
        "fmt",
        type=click.Choice(["pretty", "json", "tree"]),
        default="pretty",
        show_default=True,
        help="输出格式",
    )
    @click.option(
        "-o",
        "--output",
        type=click.Path(path_type=Path),
        help="将输出保存到文件",
    )
    @click.option(
        "-v",
        "--verbose",
        is_flag=True,
        help="显示详细的解码过程信息",
    )
    def cli(
        encoded: str | None,
        file: Path | None,
        file_format: str,
        probe: str,
        probe_max_bytes: int,
        probe_max_depth: int,
        probe_max_nodes: int,
        fmt: str,
        output: Path | None,
        verbose: bool,
    ) -> None:
        """Tars 编解码命令行工具.

        Examples:
            tarsio "00 64"
            tarsio -f payload.bin --format json
        """
        try:
            _validate_input_args(encoded, file)
        except ValueError as e:
            error_console.print(f"[red]Error:[/] {e}")
            raise SystemExit(1) from e

        policy = ProbePolicy(
            mode=probe,
            max_bytes=probe_max_bytes,
            max_depth=probe_max_depth,
            max_nodes=probe_max_nodes,
        )
        rt = ProbeRuntime()

        try:
            input_buffer = _read_input(encoded, file, file_format)
        except (OSError, UnicodeDecodeError, ValueError) as e:
            error_console.print(f"[red]Error:[/] 输入读取失败: {e}")
            raise SystemExit(1) from e

        try:
            if verbose:
                console.print(
                    f"[dim][INFO] 输入大小: {len(input_buffer.data)} bytes[/]"
                )
                preview_hex = input_buffer.data[:50].hex()
                formatted_hex = " ".join(
                    preview_hex[i : i + 2] for i in range(0, len(preview_hex), 2)
                )
                if len(input_buffer.data) > 50:
                    formatted_hex += " ..."
                console.print(f"[dim][DEBUG] Hex: {formatted_hex}[/]")
                if file is not None:
                    if file_format == "hex":
                        console.print("[dim][INFO] 文件输入格式: hex 文本[/]")
                    else:
                        console.print("[dim][INFO] 文件输入格式: 二进制[/]")

            try:
                decoded = _decode_payload(input_buffer.data, fmt)
            except Exception as e:
                error_console.print(f"[red]Error:[/] 解码失败: {e}")
                raise SystemExit(1) from e

            _render_or_dump(decoded, fmt, output, console, error_console, policy, rt)
        finally:
            input_buffer.close()

    return cli


def main() -> None:
    """入口函数."""
    cli = _create_cli()
    cli()


if __name__ == "__main__":
    main()
