"""Top API 返回模型定义."""

from pydantic import Field, field_validator

from .base import Song
from .request import Response


class TopPreviewSong(Response):
    """排行榜预览歌曲条目.

    Attributes:
        rank: 排名位置.
        rank_type: 排名变化类型.
        rank_value: 排名变化值文本.
        id: 歌曲数字 ID.
        name: 歌曲标题.
        singer_name: 歌手名称文本.
        singer_mid: 主歌手 MID.
        album_mid: 专辑 MID.
        cover: 封面地址.
        mv_id: MV 数字 ID.
    """

    rank: int
    rank_type: int = Field(alias="rankType")
    rank_value: str = Field(alias="rankValue")
    id: int = Field(alias="songId")
    name: str = Field(alias="title")
    singer_name: str = Field(alias="singerName")
    singer_mid: str = Field(alias="singerMid")
    album_mid: str = Field(alias="albumMid")
    cover: str = ""
    mv_id: int = Field(default=0, alias="mvid")


class TopSummary(Response):
    """排行榜摘要信息.

    Attributes:
        id: 排行榜 ID.
        name: 榜单标题.
        title_detail: 榜单完整标题.
        title_sub: 榜单副标题.
        intro: 榜单简介.
        period: 榜单期数.
        update_time: 更新时间.
        listen_num: 播放量.
        total_num: 榜单总曲数.
        songs: 榜单预览歌曲.
        front_pic_url: 榜单封面.
        head_pic_url: 榜单头图.
        h5_jump_url: H5 跳转地址.
        special_scheme: 客户端跳转 Scheme.
    """

    id: int = Field(alias="topId")
    name: str = Field(alias="title")
    title_detail: str = Field(alias="titleDetail")
    title_sub: str = Field(default="", alias="titleSub")
    intro: str = ""
    period: str = ""
    update_time: str = Field(default="", alias="updateTime")
    listen_num: int = Field(default=0, alias="listenNum")
    total_num: int = Field(default=0, alias="totalNum")
    songs: list[TopPreviewSong] = Field(default_factory=list, alias="song")
    front_pic_url: str = Field(default="", alias="frontPicUrl")
    head_pic_url: str = Field(default="", alias="headPicUrl")
    h5_jump_url: str = Field(default="", alias="h5JumpUrl")
    special_scheme: str = Field(default="", alias="specialScheme")


class TopCategory(Response):
    """排行榜分类.

    Attributes:
        id: 分类 ID.
        name: 分类名称.
        toplist: 分类下的排行榜摘要列表.
    """

    id: int = Field(alias="groupId")
    name: str = Field(alias="groupName")
    toplist: list[TopSummary]


class TopCategoryResponse(Response):
    """排行榜分类响应.

    Attributes:
        group: 排行榜分类列表.
    """

    group: list[TopCategory]


class TopDetailResponse(Response):
    """排行榜详情响应.

    Attributes:
        info: 排行榜基础信息.
        songs: 排行榜歌曲列表.
        song_tags: 歌曲标签列表.
        ext_info_list: 附加信息列表.
        index_info_list: 榜单索引信息列表.
    """

    @field_validator("song_tags", "ext_info_list", "index_info_list", mode="before")
    @classmethod
    def _coerce_none_list(cls, value: list[dict] | None) -> list[dict]:
        """将上游返回的空列表占位统一规整为列表."""
        return [] if value is None else value

    info: TopSummary = Field(alias="data")
    songs: list[Song] = Field(alias="songInfoList")
    song_tags: list[dict] = Field(default_factory=list, alias="songTagInfoList")
    ext_info_list: list[dict] = Field(default_factory=list, alias="extInfoList")
    index_info_list: list[dict] = Field(default_factory=list, alias="indexInfoList")
