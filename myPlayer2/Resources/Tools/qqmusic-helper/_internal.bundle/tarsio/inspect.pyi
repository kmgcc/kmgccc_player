"""Tarsio 类型内省.

主要用途：

- 在开发阶段对 `typing.Annotated` 字段标注进行静态建模
- 提供 `type_info()` / `struct_info()` 的返回对象结构（`kind` 分支 + 关联字段）
"""

from typing import Any, TypeAlias, TypeVar

T = TypeVar("T")

class Type:
    """类型内省基类.

    Attributes:
        kind: 类型分支标识。
    """

    kind: str

class BasicType(Type):
    """基础标量类型基类."""

class CompoundType(Type):
    """复合容器类型基类."""

class IntType(BasicType):
    """整数类型（JCE int 家族的抽象视图）.

    编码：`ZeroTag` 或 `Int1/Int2/Int4/Int8`。
    """

    gt: float | None
    lt: float | None
    ge: float | None
    le: float | None

class StrType(BasicType):
    """字符串类型.

    编码：`String1` 或 `String4`。
    """

    min_length: int | None
    max_length: int | None
    pattern: str | None

class FloatType(BasicType):
    """浮点类型（运行时对应 double 语义）.

    编码：`ZeroTag` 或 `Double`。
    """

    gt: float | None
    lt: float | None
    ge: float | None
    le: float | None

class BoolType(BasicType):
    """布尔类型（在 JCE 编码层面通常以 int 表达）.

    编码：`ZeroTag` 或 `Int1/Int2/Int4/Int8`。
    """

class BytesType(BasicType):
    """二进制类型（运行时会被视为 byte-list 的特殊形式）.

    编码：`SimpleList`。
    """

    min_length: int | None
    max_length: int | None

class AnyType(BasicType):
    """动态类型（运行时根据值推断编码）.

    编码：运行时按值类型选择具体 TarsType。
    """

class NoneType(BasicType):
    """None 类型（通常仅出现在 Union/Optional 中）.

    编码：不能直接编码，仅用于 Optional/Union 的语义分支。
    """

class EnumType(CompoundType):
    """Enum 类型.

    编码：取 `value` 的内层类型映射。

    Attributes:
        cls: 枚举类型。
        value_type: 枚举值的类型内省结果。
    """

    cls: type
    value_type: TypeInfo

class UnionType(CompoundType):
    """Union 类型（非 Optional 形式）.

    编码：按变体顺序匹配实际值，直接按匹配类型编码。

    Attributes:
        variants: 变体类型列表。
    """

    variants: tuple[TypeInfo, ...]

class ListType(CompoundType):
    """列表类型：`list[T]`.

    编码：`List`（若元素类型为 int 且值为 bytes，则使用 `SimpleList`）。

    Attributes:
        item_type: 元素类型。
    """

    item_type: TypeInfo
    min_length: int | None
    max_length: int | None

class TupleType(CompoundType):
    """元组类型：固定长度、固定类型 `tuple[T1, T2, ...]`.

    编码：`List`。

    Attributes:
        items: 元素类型列表。
    """

    items: tuple[TypeInfo, ...]
    min_length: int | None
    max_length: int | None

class VarTupleType(CompoundType):
    """元组类型：可变长度、元素类型相同 `tuple[T, ...]`.

    编码：`List`（若元素类型为 int 且值为 bytes，则使用 `SimpleList`）。

    Attributes:
        item_type: 元素类型。
    """

    item_type: TypeInfo
    min_length: int | None
    max_length: int | None

class MapType(CompoundType):
    """映射类型：`dict[K, V]`.

    编码：`Map`。

    Attributes:
        key_type: 键类型。
        value_type: 值类型。
    """

    key_type: TypeInfo
    value_type: TypeInfo
    min_length: int | None
    max_length: int | None

class SetType(CompoundType):
    """集合类型：`set[T]` / `frozenset[T]`.

    编码：`List`，解码为 set。

    Attributes:
        item_type: 元素类型。
    """

    item_type: TypeInfo
    min_length: int | None
    max_length: int | None

class OptionalType(CompoundType):
    """可选类型：`T | None` 或 `typing.Optional[T]`.

    编码：None 时不写 tag，有值时按内层类型映射。

    Attributes:
        inner_type: 内层类型。
    """

    inner_type: TypeInfo

class StructType(CompoundType):
    """Struct 类型：字段类型为另一个 `tarsio.Struct` 子类.

    编码：`StructBegin` ... `StructEnd`。

    Attributes:
        cls: Struct 类型。
        fields: 字段列表，按 tag 升序。
    """

    cls: type
    fields: tuple[Field, ...]

class RefType(CompoundType):
    """引用类型：用于递归结构中的循环引用节点.

    Attributes:
        cls: 被引用的 Struct 类型。
    """

    cls: type

class TypedDictType(CompoundType):
    """TypedDict 类型.

    编码：`Map`。
    """

class NamedTupleType(CompoundType):
    """NamedTuple 类型.

    编码：`List`。

    Attributes:
        cls: NamedTuple 类型。
        items: 元素类型列表。
    """

    cls: type
    items: tuple[TypeInfo, ...]

class DataclassType(CompoundType):
    """Dataclass 类型.

    编码：`Map`。

    Attributes:
        cls: Dataclass 类型。
    """

    cls: type

class TarsDictType(CompoundType):
    """TarsDict 类型（动态 struct 字段映射）.

    编码：`StructBegin` ... `StructEnd`。
    """

TypeInfo: TypeAlias = (
    IntType
    | StrType
    | FloatType
    | BoolType
    | BytesType
    | AnyType
    | NoneType
    | TypedDictType
    | NamedTupleType
    | DataclassType
    | EnumType
    | UnionType
    | ListType
    | TupleType
    | VarTupleType
    | MapType
    | SetType
    | OptionalType
    | StructType
    | RefType
    | TarsDictType
)

class Field:
    """结构体字段信息.

    Attributes:
        name: 字段名。
        tag: 字段 tag。
        type: 字段类型内省结果。
        default: 字段默认值。
        default_factory: 字段默认值工厂；无工厂时为 `tarsio.NODEFAULT`。
        has_default: 是否显式有默认值。
        optional: 是否可选。
        required: 是否必填。
    """

    name: str
    tag: int
    type: TypeInfo
    default: Any
    default_factory: Any
    has_default: bool
    optional: bool
    required: bool

FieldInfo: TypeAlias = Field

class StructInfo:
    """结构体信息（类级 Schema 视图）.

    Attributes:
        cls: 结构体类型。
        fields: 字段列表，按 tag 升序。
    """

    cls: type
    fields: tuple[Field, ...]

def type_info(tp: Any) -> TypeInfo:
    """将类型标注解析为 Tarsio 的类型内省结果.

    Args:
        tp: 需要解析的类型标注，支持内置类型（如 `int/str/bytes`）、容器类型
            （如 `list[T]`、`tuple[T]`、`dict[K, V]`）、Optional/Union 形式，
            以及 `typing.Annotated[T, ...]`（会解析其中的 `Meta` 约束信息）。

    Returns:
        解析后的 `TypeInfo` 实例，可通过其 `kind` 字段区分具体分支，并读取对应属性。

    Raises:
        TypeError: 当类型标注不受支持或包含未支持的前向引用时抛出。
    """

def struct_info(cls: type) -> StructInfo | None:
    """解析 Struct 类并返回字段定义信息.

    Args:
        cls: 需要解析的 `tarsio.Struct` 子类。

    Returns:
        `StructInfo` 对象，包含字段列表（按 tag 升序）；如果该类没有可用字段，
        或该类是未具体化的泛型模板，则返回 `None`。

    Raises:
        TypeError: 当字段缺少 tag、tag 重复、混用整数 tag 与 `Meta`，或字段类型不受支持时抛出。
    """
