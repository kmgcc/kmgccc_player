"""Tarsio 统一编解码 API.

本模块提供了核心的序列化与反序列化接口，封装了底层的 Rust 实现，
并提供了完整的类型提示与文档。
"""

from typing import Any, TypeVar, get_origin, overload

from ._core import Struct, TarsDict
from ._core import (
    decode as _core_decode,
)
from ._core import (
    decode_raw as _core_decode_raw,
)
from ._core import (
    encode as _core_encode,
)
from ._core import (
    encode_raw as _core_encode_raw,
)

_StructT = TypeVar("_StructT")
_BytesLike = bytes | bytearray | memoryview

__all__ = [
    "decode",
    "encode",
]


def encode(obj: Any) -> bytes:
    """将对象序列化为 Tars 二进制格式.

    该函数会自动根据输入对象的类型选择合适的编码模式：
    1. **Schema 模式**：如果对象是 `Struct`、`dataclass`、`NamedTuple` 或 `TypedDict` 实例，
       将按照其定义的 Schema 进行编码。
    2. **Raw 模式**：如果对象是 `TarsDict`、 `dict`、`list` 或基本类型，
       将进行原始编码（无 Schema）。

    Args:
        obj: 要编码的对象。

    Returns:
        包含序列化数据的 bytes 对象。

    Raises:
        TypeError: 如果对象既不是有效的 Struct 也不是支持的 Raw 类型。
        ValueError: 如果数据校验失败。
    """
    # 优先处理显式的 Raw 容器和基本类型
    if isinstance(
        obj, (TarsDict, dict, list, tuple, set, int, float, str, bytes, bool)
    ):
        return _core_encode_raw(obj)

    # 尝试作为 Struct 处理 (Struct)
    # 优化：通过检查特征属性避免 try-except 开销
    if isinstance(obj, Struct):
        return _core_encode(obj)

    # 如果不是 Struct，最后尝试 Raw 兜底
    return _core_encode_raw(obj)


@overload
def decode(data: _BytesLike) -> TarsDict: ...


@overload
def decode(
    data: _BytesLike,
    cls: type[TarsDict],
) -> TarsDict: ...


@overload
def decode(
    data: _BytesLike,
    cls: type[_StructT],
) -> _StructT: ...


def decode(
    data: _BytesLike,
    cls: type = TarsDict,
) -> Any:
    """从 Tars 二进制数据反序列化.

    Args:
        data: 二进制数据。
        cls: 目标类。省略或传入 TarsDict 时返回 Raw 解码结果。

    Returns:
        反序列化的类实例或 TarsDict。

    Raises:
        TypeError: 参数类型错误、目标类未注册 Schema、或目标类不是 Struct/TarsDict。
        ValueError: 数据格式不正确。
    """
    origin_cls = get_origin(cls) or cls

    if origin_cls is TarsDict:
        return _core_decode_raw(data)

    if isinstance(origin_cls, type) and issubclass(origin_cls, Struct):
        return _core_decode(origin_cls, data)

    raise TypeError("decode cls must be TarsDict or a Struct subclass")
