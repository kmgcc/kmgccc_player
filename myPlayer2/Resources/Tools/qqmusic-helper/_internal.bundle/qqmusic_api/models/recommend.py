"""Recommend API 返回模型定义."""

from typing import Any

from pydantic import AliasChoices, Field, model_validator

from .base import Song, SongList
from .request import Response


class RecommendNiche(Response):
    """首页推荐楼层中的细分卡片分组, 保留标题信息与原始卡片列表.

    Attributes:
        id: 细分分组 ID.
        title_template: 标题模板.
        title_content: 标题实际展示内容.
        cards: 原始卡片列表.
    """

    id: int
    title_template: str
    title_content: str
    cards: list[dict[str, Any]] = Field(alias="v_card")


class RecommendShelf(Response):
    """首页推荐页中的单个楼层, 聚合楼层标题、更多入口与下属细分分组.

    Attributes:
        id: 楼层 ID.
        title_template: 楼层标题模板.
        title_content: 楼层标题实际展示内容.
        more: 更多入口信息.
        niches: 楼层下属的细分分组列表.
    """

    id: int
    title_template: str
    title_content: str
    more: dict[str, Any] = Field()
    niches: list[RecommendNiche] = Field(alias="v_niche")


class RecommendFeedCardResponse(Response):
    """首页推荐首屏响应, 包含楼层化推荐内容及继续加载所需的状态字段.

    Attributes:
        retcode: 接口返回码.
        msg: 附加消息.
        prompt: 提示信息.
        d_num: 分页或批次计数信息.
        load_mark: 继续加载标记.
        shelves: 首页推荐楼层列表.
    """

    retcode: int
    msg: str
    prompt: str
    d_num: int
    load_mark: int
    shelves: list[RecommendShelf] = Field(alias="v_shelf")


class GuessRecommendResponse(Response):
    """“猜你喜欢”接口响应, 返回按接口顺序展开的推荐歌曲列表.

    Attributes:
        songs: 推荐歌曲列表.
    """

    songs: list[Song] = Field(default_factory=list, alias="Tracks")

    @model_validator(mode="before")
    @classmethod
    def _normalize_tracks(cls, data: Any) -> Any:
        """将猜你喜欢响应规整为稳定的歌曲列表载荷."""
        if isinstance(data, dict) and "Tracks" not in data:
            return {"Tracks": []}
        return data


class RadarRecommendResponse(Response):
    """雷达推荐响应, 返回推荐歌曲及继续刷新推荐流所需的上下文信息.

    Attributes:
        songs: 推荐歌曲列表.
        recommend_song_ids: 推荐歌曲 ID 列表.
        base_song_ids: 作为推荐依据的基础歌曲 ID 列表.
        has_more: 是否还能继续获取更多推荐.
        toast: 提示信息块或提示文案.
        timestamp: 服务端时间戳.
        video_cards: 关联视频卡片数据.
    """

    songs: list[Song] = Field(json_schema_extra={"jsonpath": "$.VecSongs[*].Track"})
    recommend_song_ids: list[int] = Field(alias="RecommendSongIds")
    base_song_ids: list[int] = Field(alias="BaseSongIds")
    has_more: bool = Field(alias="HasMore")
    toast: str = ""
    timestamp: int = Field(alias="TimeStamp")
    video_cards: dict[str, Any] = Field(alias="VideoCards")


class RecommendSonglistItem(SongList):
    """推荐歌单列表中的单个歌单摘要, 补充封面、播放量与创建者昵称.

    Attributes:
        picurl: 歌单封面地址.
        songnum: 歌单歌曲数量.
        listennum: 歌单播放量.
        creator_nick: 创建者昵称.
    """

    picurl: str = Field(default="", json_schema_extra={"jsonpath": "$.cover.default_url"})
    songnum: int = Field(default=0, validation_alias=AliasChoices("song_cnt", "songnum", "songNum"))
    listennum: int = Field(default=0, validation_alias=AliasChoices("play_cnt", "listennum", "playCnt"))
    creator_nick: str = Field(default="", json_schema_extra={"jsonpath": "$.creator.nick"})


class RecommendSonglistResponse(Response):
    """推荐歌单分页响应, 返回当前批次歌单及是否还能继续拉取更多内容.

    Attributes:
        songlists: 当前批次推荐歌单列表.
        has_more: 是否还能继续拉取更多歌单.
        from_limit: 当前批次对应的偏移或起始位置.
        msg: 附加消息.
    """

    songlists: list[RecommendSonglistItem] = Field(
        json_schema_extra={"jsonpath": "$.List[*].Playlist.basic"},
    )
    has_more: bool = Field(alias="HasMore")
    from_limit: int = Field(alias="FromLimit")
    msg: str = Field(alias="Msg")


class RecommendNewSongTag(Response):
    """推荐新歌页的标签项, 用于标识当前新歌流所属的频道或筛选维度.

    Attributes:
        id: 标签记录 ID.
        tagid: 标签 ID.
        tag: 标签名称.
        link: 标签跳转链接.
        from_type: 标签来源类型.
    """

    id: int
    tagid: int
    tag: str
    link: str
    from_type: int


class RecommendNewSongResponse(Response):
    """推荐新歌响应, 返回当前语言或频道下的新歌列表及可选标签信息.

    Attributes:
        lanlist: 可选语言或频道列表.
        lan: 当前语言或频道标识.
        songs: 当前新歌列表.
        ret_msg: 附加返回消息.
        type: 当前推荐类型标记.
        song_tags: 新歌标签列表.
    """

    lanlist: list[dict[str, Any]] = Field()
    lan: str
    songs: list[Song] = Field(alias="songlist")
    ret_msg: str
    type: int
    song_tags: list[RecommendNewSongTag] = Field(alias="songTagInfoList")
