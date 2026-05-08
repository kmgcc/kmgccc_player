"""Tarsio 公共 Python API.

本模块导出 Tarsio 的核心类型与编解码接口，包含基类 `Struct`、元类
`StructMeta`、配置对象 `StructConfig` 以及编码/解码函数。
"""

from collections.abc import Callable
from inspect import Signature
from typing import Any, ClassVar, Final, TypeVar, overload

from typing_extensions import dataclass_transform

from . import inspect

_StructT = TypeVar("_StructT")
_SM = TypeVar("_SM", bound="StructMeta")
_FieldDefaultT = TypeVar("_FieldDefaultT")
_BytesLike = bytes | bytearray | memoryview

__all__ = [
    "NODEFAULT",
    "Meta",
    "Struct",
    "StructConfig",
    "StructMeta",
    "TarsDict",
    "TraceNode",
    "ValidationError",
    "decode",
    "decode_raw",
    "decode_trace",
    "encode",
    "encode_raw",
    "field",
    "inspect",
    "probe_struct",
]

NODEFAULT: Final[object]

@overload
def field(
    *,
    tag: int | None = None,
    wrap_simplelist: bool = ...,
) -> Any: ...
@overload
def field(
    *,
    tag: int | None = None,
    default: Any,
    wrap_simplelist: bool = ...,
) -> Any: ...
@overload
def field(
    *,
    tag: int | None = None,
    wrap_simplelist: bool = ...,
    default_factory: Callable[[], _FieldDefaultT],
) -> _FieldDefaultT: ...
def field(
    *,
    tag: int | None = None,
    default: Any = NODEFAULT,
    wrap_simplelist: bool = False,
    default_factory: Any = NODEFAULT,
) -> Any:
    """声明字段默认值或默认值工厂.

    Args:
        tag: 字段 Tag, 范围 0-255。省略时自动分配。
        default: 字段默认值。
        wrap_simplelist: 是否将 Struct/TarsDict 字段包装为 SimpleList(bytes)。
            仅在字段注解为 Struct 或 TarsDict 时有效。
        default_factory: 字段默认值工厂（可调用对象）。

    Returns:
        内部字段规格对象。

    Raises:
        TypeError: 同时提供 default 与 default_factory，default_factory 不可调用，
            或 wrap_simplelist 非 bool 时抛出。
    """
    ...

class TarsDict(dict[int, Any]):
    """TarsDict 是一个特殊的字典类型，用于表示 Tars 结构中的 Tag-Value 映射.

    在 Tars 编解码过程中，TarsDict 用于存储和传递原始的 Tag-Value 数据，特别是在
    `encode_raw` 和 `decode_raw` 函数中。它的键是整数 Tag，值可以是任意类型（通常是
    基础类型、嵌套的 TarsDict 或列表）。

    Examples:
        ```python
        from tarsio import TarsDict, encode

        # 构造一个 TarsDict
        data = TarsDict(
            {
                0: 123,  # Tag 0: int
                1: "hello",  # Tag 1: str
                2: [1, 2, 3],  # Tag 2: list
            }
        )

        # 编码为 bytes
        encoded = encode(data)
        ```
    """

    ...

class ValidationError(ValueError):
    """解码阶段的校验错误.

    由 `Meta` 约束或 Schema 校验失败触发。

    错误消息包含路径与原因，典型格式：
    `Error at <root>.<field>.<tag:N>: <reason>`。

    Notes:
        当前版本不提供结构化字段访问器（如 `field_name`、`tag` 属性）。
        建议在业务侧解析异常消息中的路径片段。
    """

    ...

class Meta:
    """字段元数据与约束定义.

    用于在 `Annotated` 中提供运行时校验约束。

    Examples:
        ```python
        from typing import Annotated
        from tarsio import Struct, Meta, field

        class Product(Struct):
            # 价格必须 > 0
            price: Annotated[int, Meta(gt=0)] = field(tag=0)
            # 代码必须是 1-10 位大写字母
            code: Annotated[str, Meta(min_len=1, max_len=10, pattern=r"^[A-Z]+$")] = (
                field(tag=1)
            )
        ```
    """
    def __init__(
        self,
        gt: float | None = ...,
        lt: float | None = ...,
        ge: float | None = ...,
        le: float | None = ...,
        min_len: int | None = ...,
        max_len: int | None = ...,
        pattern: str | None = ...,
    ) -> None:
        """初始化字段元数据.

        Args:
            gt: 数值必须大于该值。
            lt: 数值必须小于该值。
            ge: 数值必须大于或等于该值。
            le: 数值必须小于或等于该值。
            min_len: 长度下限。
            max_len: 长度上限。
            pattern: 正则表达式约束。
        """
        ...

    gt: float | None
    lt: float | None
    ge: float | None
    le: float | None
    min_len: int | None
    max_len: int | None
    pattern: str | None

@dataclass_transform(
    eq_default=True,
    order_default=False,
    kw_only_default=False,
    frozen_default=False,
    field_specifiers=(field,),
)
class StructMeta(type):
    """Struct 的元类.

    用于在定义 `Struct` 子类时，在类创建期编译并注册 Schema，并生成相应的构造行为与
    运行时元信息（如 `__struct_fields__`、`__struct_config__`、`__signature__`）。
    """

    __struct_fields__: ClassVar[tuple[str, ...]]
    @property
    def __signature__(self) -> Signature: ...
    @property
    def __struct_config__(self) -> StructConfig: ...
    def __new__(
        mcls: type[_SM],
        name: str,
        bases: tuple[type, ...],
        namespace: dict[str, Any],
        /,
        *,
        frozen: bool = ...,
        order: bool = ...,
        forbid_unknown_tags: bool = ...,
        eq: bool = ...,
        omit_defaults: bool = ...,
        repr_omit_defaults: bool = ...,
        kw_only: bool = ...,
        dict: bool = ...,
        weakref: bool = ...,
        **kwargs: Any,
    ) -> _SM:
        """创建 Struct 子类并编译 Schema.

        Args:
            mcls: 元类本身。
            name: 类名。
            bases: 基类。
            namespace: 类命名空间。
            frozen: 是否冻结实例。
            order: 是否生成排序比较方法。
            forbid_unknown_tags: 是否禁止未知 Tag。
            eq: 是否生成相等比较。
            omit_defaults: 编码时是否省略默认值字段。
            repr_omit_defaults: repr 是否省略默认值字段。
            kw_only: 是否只允许关键字参数构造。
            dict: 是否为实例保留 `__dict__`。
            weakref: 是否支持弱引用。
            **kwargs: 预留扩展配置。

        Returns:
            新创建的 Struct 子类。
        """
        ...

class StructConfig:
    """Struct 的配置对象.

    该对象反映 `Struct` 子类在定义时传入的配置选项，可通过
    `Struct.__struct_config__` 或实例的 `__struct_config__` 访问。

    Attributes:
        frozen: 是否冻结实例（不可变）。
        eq: 是否启用值相等比较。
        order: 是否启用排序比较。
        kw_only: 构造函数是否仅接受关键字参数。
        repr_omit_defaults: `repr` 是否省略默认值字段。
        omit_defaults: 编码时是否省略默认值字段。
        weakref: 是否支持弱引用。
        dict: 是否保留 `__dict__`（允许动态属性）。
        rename: 预留字段（当前默认未启用）。
    """

    frozen: bool
    eq: bool
    order: bool
    kw_only: bool
    repr_omit_defaults: bool
    omit_defaults: bool
    weakref: bool
    dict: bool
    rename: Any | None

class Struct(metaclass=StructMeta):
    """高性能可序列化结构体基类.

    `Struct` 用于定义可编码/解码的 Tars/JCE 数据结构。字段通过类型注解声明，
    tag 支持显式与隐式混合：

    - 显式 tag：通过 `field(tag=...)` 指定。
    - 隐式 tag：未显式指定时按字段定义顺序自动分配。
      当未显式指定的字段位于显式 tag 字段之后时，会从该显式 tag 继续递增分配。

    `Annotated` 仅用于附加 `Meta` 约束，不再负责声明 tag。

    字段可以提供默认值。带默认值的字段在构造函数中表现为可选参数；当字段是 Optional 且未
    显式提供默认值时，其默认值视为 `None`。

    Struct 会提供/生成以下能力：

    - `__init__`：支持按 Tag 顺序的 positional 参数，以及按字段名的 keyword 参数。
    - `__eq__`：当 `eq=True` 时生成相等比较。
    - `__repr__`：生成可读的 repr；当 `repr_omit_defaults=True` 时省略默认值字段。
    - `__copy__`：生成浅拷贝。
    - `__post_init__`：若定义则在实例初始化完成后调用（包括解码路径）。
    - `__replace__`：返回替换指定字段后的新实例。
    - `__match_args__`：用于模式匹配的位置参数顺序。
    - `__rich_repr__`：为 rich pretty-print 提供字段迭代项。
    - 排序比较：当 `order=True` 时生成 `__lt__/__le__/__gt__/__ge__`。
    - Hash: 当 `frozen=True` 时提供 `__hash__`（使实例可哈希）。

    运行时元信息：

    - `__struct_fields__`：字段名元组，按 Tag 升序排列。
    - `__struct_config__`：配置对象（见 `StructConfig`）。

    Configuration:
        可在定义 `Struct` 子类时传入关键字参数控制行为：

        - frozen (bool, default False): 是否冻结实例。冻结后禁止属性赋值，并提供 `__hash__`。
        - order (bool, default False): 是否生成排序比较方法。
        - eq (bool, default True): 是否生成 `__eq__`。
        - kw_only (bool, default False): 是否将所有字段设为仅关键字参数。
        - omit_defaults (bool, default False): 编码时是否省略值等于默认值的字段。
        - repr_omit_defaults (bool, default False): repr 是否省略值等于默认值的字段。
        - forbid_unknown_tags (bool, default False): 解码时是否禁止出现未知 Tag.
        - dict (bool, default False): 是否为实例保留 `__dict__`（允许附加额外属性）。
        - weakref (bool, default False): 是否支持弱引用。

    Examples:
        基本用法：

        ```python
        from typing import Annotated
        from tarsio import Meta, Struct, field

        class User(Struct):
            uid: int = field(tag=0)
            name: str  # 自动分配 tag=1
            score: Annotated[int, Meta(ge=0)] = field(tag=2, default=0)

        user = User(uid=1, name="Ada")
        data = user.encode()
        restored = User.decode(data)
        assert restored == user
        ```

        启用配置项：

        ```python
        from tarsio import Struct, field

        class Point(Struct, frozen=True, order=True):
            x: int = field(tag=0)
            y: int = field(tag=1)
        ```
    """

    __struct_fields__: ClassVar[tuple[str, ...]]
    __struct_config__: ClassVar[StructConfig]
    __match_args__: ClassVar[tuple[str, ...]]

    def __init_subclass__(
        cls,
        *,
        frozen: bool = False,
        order: bool = False,
        forbid_unknown_tags: bool = False,
        eq: bool = True,
        omit_defaults: bool = False,
        repr_omit_defaults: bool = False,
        kw_only: bool = False,
        dict: bool = False,
        weakref: bool = False,
        **kwargs: Any,
    ) -> None:
        """配置 Struct 子类行为."""
        ...
    @classmethod
    def __class_getitem__(cls, params: Any) -> Any:
        """返回参数化后的 Struct 类型.

        - 未具体化模板允许实例化，TypeVar 会按 bound/constraints/Any 进行运行时解释。
        - 具体化参数（如 `Box[int]`）会生成可缓存复用的具体类型，并参与严格校验。
        - 若参数中仍包含未解析 TypeVar，则返回通用 GenericAlias 以支持继续组合泛型。
        """
        ...
    def encode(self) -> bytes:
        """将当前实例编码为 Tars 二进制数据.

        Returns:
            编码后的 bytes。

        Raises:
            ValueError: 缺少必填字段或类型不匹配。
        """
        ...
    @classmethod
    def decode(cls: type[_StructT], data: _BytesLike) -> _StructT:
        """将 Tars 二进制数据解码为当前类实例.

        Args:
            data: 待解码的 bytes。

        Returns:
            解码得到的实例。

        Raises:
            TypeError: 目标类未注册 Schema。
            ValueError: 数据格式不正确或缺少必填字段。
            ValidationError: 解码后 `__post_init__` 抛出 TypeError/ValueError。
        """
        ...
    def __replace__(self: _StructT, **changes: Any) -> _StructT:
        """返回替换部分字段后的新实例.

        Args:
            **changes: 需要替换的字段名和值。

        Returns:
            新实例，未替换字段沿用原实例值。

        Raises:
            TypeError: 包含未知字段名时抛出。
            ValidationError: 替换值不满足类型或约束时抛出。
        """
        ...
    def __rich_repr__(self) -> list[tuple[str, Any]]:
        """返回 rich pretty-print 使用的字段序列.

        Returns:
            形如 ``[(field_name, value), ...]`` 的字段序列，顺序按 tag。
        """
        ...

def encode(obj: Any) -> bytes:
    """将 Tars Struct 对象序列化为 Tars 二进制格式.

    Args:
        obj: `Struct`、dataclass、NamedTuple、TypedDict 的实例。

    Returns:
        包含序列化数据的 bytes 对象。

    Raises:
        TypeError: 如果对象不是有效的 Tars Struct。
    """
    ...

def decode(cls: type[_StructT], data: _BytesLike) -> _StructT:
    """从 Tars 二进制数据反序列化为类实例.

    Args:
        cls: 目标类（`Struct`、dataclass、NamedTuple、TypedDict）。
        data: 包含 Tars 编码数据的 bytes 对象。

    Returns:
        反序列化的类实例。

    Raises:
        TypeError: 如果类未注册 Schema。
        ValueError: 如果数据格式不正确。
    """
    ...

def encode_raw(obj: Any) -> bytes:
    """将对象编码为 Tars 二进制格式 (原始模式).

    如果输入是 `TarsDict`，则按结构体编码；否则按其自然类型（Map, List, Int 等）编码。
    Raw 模式下，`Struct` 实例在任意嵌套位置都允许编码为 Struct。

    Args:
        obj: 要编码的对象。

    Returns:
        编码后的字节对象。
    """
    ...

def decode_raw(data: _BytesLike) -> TarsDict:
    """将字节解码为 TarsDict.

    Args:
        data: 包含 Tars 编码数据的 bytes 对象。

    Returns:
        解码后的 TarsDict。
        Raw 模式下，任意嵌套层级的 StructBegin 都会还原为 TarsDict。
    """
    ...

def probe_struct(data: bytes) -> TarsDict | None:
    """尝试将字节数据递归解析为 Tars 结构.

    这是一个启发式工具，用于探测一段二进制数据是否恰好是有效的 Tars 序列化结构。
    它不仅检查格式，还会验证是否完全消费了数据。

    Args:
        data: 可能包含 Tars 结构的二进制数据。

    Returns:
        如果解析成功且数据完整，返回 TarsDict；否则返回 None。
    """
    ...

class TraceNode:
    """`decode_trace` 返回的调试树节点.

    Attributes:
        tag: 当前节点对应的 Tag。
        jce_type: JCE 类型名。
        value: 当前节点值（容器节点通常为 None）。
        children: 子节点列表。
        name: 字段名（有 Schema 时可用）。
        type_name: 类型名（有 Schema 时可用）。
        path: 从根开始的可读路径。
    """

    tag: int
    jce_type: str
    value: Any | None
    children: list[TraceNode]
    name: str | None
    type_name: str | None
    path: str

    def to_dict(self) -> dict[str, Any]: ...

def decode_trace(data: bytes, cls: type[Any] | None = None) -> TraceNode:
    """解析二进制数据并生成追踪树.

    Args:
        data: Tars 二进制数据.
        cls: 可选的 Struct 类型，用于提供 Schema 信息.

    Returns:
        根 TraceNode 对象.
    """
    ...
