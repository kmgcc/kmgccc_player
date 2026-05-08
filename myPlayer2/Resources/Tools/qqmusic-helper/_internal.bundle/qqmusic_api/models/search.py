"""Search API 返回模型定义."""

from typing import Any, Generic, TypeVar

from pydantic import Field

from .base import MV, Album, Singer, Song, SongList
from .request import Response


class SongSearch(Song):
    """搜索场景下的歌曲详尽模型.

    Attributes:
        search_title: 搜索命中的标题 (可能包含高亮标签).
        title_main: 歌曲主标题.
        title_extra: 歌曲附加标题.
        fav_show: 收藏数展示文案 (如 "5500w+").
        tag: 标签 ID.
        desc: 歌曲描述文案.
        desc_icon: 描述文案前的图标链接.
        content: 搜索结果内容摘要,当搜索命中歌词或特定评论时,该字段存放命中的文本片段.
        hotness: 热度数据对象.
        hotness_desc: 热度描述 (如榜单名).
        vec_hotness: 热度榜单详情列表.
        new_status: 新版状态位 (2: 正常).
        protect: 是否受到版权保护.
        relatedword_group: 相关搜索词推荐组.
    """

    search_title: str
    title_main: str
    title_extra: str
    fav_show: str
    desc: str
    desc_icon: str
    hotness: dict[str, Any] = Field()
    hotness_desc: str
    vec_hotness: list[dict[str, Any]] = Field()
    content: str
    new_status: int = Field(alias="newStatus")
    protect: int
    relatedword_group: dict[str, Any] = Field()


class AlbumSearch(Album):
    """搜索场景下的专辑详尽模型.

    Attributes:
       album_type: 专辑类型标识 (来自 $.core_album_config.album_type).通常 1 代表正规专辑.
       singer: 搜索命中的高亮歌手名称.通常包含 `<em>` 标签.
       singer_list: 结构化的歌手对象列表.包含歌手的数字 ID 和标准名称.
       pic: 专辑封面图片 URL (通常为 180x180 或 300x300 规格).
       pic_icon: 封面配套显示的勋章或类型图标链接.
       publish_date: 专辑发行日期 (YYYY-MM-DD).
       description: 简短描述文案.在搜索结果中常存放发行日期或厂牌.
       description2: 备用描述文案.
       desc_detail: 详尽描述对象.包含长篇专辑介绍及背景信息.
       hotness: 热度数据对象.包含收藏量、趋势等原始数值.
       hotness_desc: 热度简述文案.如“全网热搜”、“飙升榜前十”.
       audio_play: 播放排行信息.包含榜单名称及具体排名.
       label_new: 专辑关联的特性标签对象.
       tag_list: 专辑标签列表.用于 UI 显示“数字专辑”、“独家”等勋章.
       url: 静态元数据下载链接.
    """

    class RankingInfo(Response):
        """歌曲排行信息.

        Attributes:
            rank: 歌曲或专辑在对应榜单中的具体排名.
            toplist: 所属的榜单名称(如“热歌榜”、“流行指数榜”).
        """

        rank: str
        toplist: str

    desc_detail: dict[str, Any]
    description: str
    description2: str = ""
    type: int = Field(0, json_schema_extra={"jsonpath": "$.core_album_config.album_type"})
    award_label: str = Field("", json_schema_extra={"jsonpath": "$.core_album_config.award_label"})
    hotness: dict[str, Any]
    hotness_desc: str
    label_new: dict[str, Any]
    audio_play: RankingInfo
    pic: str
    pic_icon: str
    singer: str
    singer_list: list[Singer]
    tag_list: list[str]
    url: str


class SongListSearch(SongList):
    """搜索结果中的歌单摘要模型.

    Attributes:
        nickname: 歌单创建者昵称.
        dirtype: 歌单目录类型标识.
    """

    nickname: str
    dirtype: int = 0


class SingerSearch(Singer):
    """搜索场景下的歌手模型.

    Attributes:
        pic: 歌手头像地址.
        song_num: 歌曲数量.
        album_num: 专辑数量.
        mv_num: MV 数量.
        subtitle: 补充描述文案.
    """

    pic: str = Field(alias="singerPic")
    song_num: int = Field(alias="songNum")
    album_num: int = Field(alias="albumNum")
    mv_num: int = Field(alias="mvNum")
    subtitle: str


class MvSearch(MV):
    """搜索场景下的 MV 模型.

    Attributes:
        pic: MV 封面地址.
        play_count: MV 播放量.
        duration: MV 时长.
        publish_date: 发布时间.
        singer_id: 歌手 ID.
        singer_mid: 歌手 MID.
        singer_name: 歌手名称.
    """

    pic: str = Field(alias="pic")
    play_count: int = Field(alias="play_count")
    duration: int
    publish_date: str = Field(alias="publish_date")
    singer_id: int = Field(alias="singerid")
    singer_mid: str = Field(alias="singermid")
    singer_name: str = Field(alias="singername")


T = TypeVar("T")


class GeneralSearchRequestBody(Response, Generic[T]):
    """综合搜索中单个分类桶的结果容器.

    Attributes:
        estimate_sum: 搜索命中的预估总记录数.
        total_num: 搜索命中的确切总记录数.
        items: 当前分类下已展开的业务实体列表.
        more_info: 继续加载该分类结果时需要回传的翻页上下文.
    """

    estimate_sum: int = 0
    total_num: int = 0
    items: list[T] = Field(default_factory=list)
    more_info: dict[str, Any] = Field(default_factory=dict)


class RelatedSearchWord(Response):
    """相关搜索词推荐.

    Attributes:
        display: 相关搜索词展示文案.
        search: 相关搜索词实际搜索关键词.
    """

    display: str = Field(alias="display_word")
    search: str = Field(alias="search_word")


class SearchByTypeResponse(Response):
    """按指定类型搜索时的响应模型.

    它将元信息与对应分类的实体列表放在同一对象中,便于直接消费该类型下的当前页结果.

    Attributes:
        searchid: 搜索会话 ID,用于后续相关请求.
        perpage: 每页结果数量.
        nextpage: 下一页页码,-1 表示已加载全部结果.
        estimate_sum: 搜索命中的预估总记录数.
        total_num: 搜索命中的确切总记录数.
        song: 单曲、歌词或节目类型下的结果列表.
        singer: 歌手结果列表.
        album: 专辑结果列表.
        songlist: 歌单结果列表.
        user: 用户结果列表.
        audio_alum: 节目专辑结果列表.
        mv: MV 结果列表.
    """

    searchid: str = Field(json_schema_extra={"jsonpath": "$.meta.searchid"})
    perpage: int = Field(json_schema_extra={"jsonpath": "$.meta.perpage"})
    nextpage: int = Field(json_schema_extra={"jsonpath": "$.meta.nextpage"})
    estimate_sum: int = Field(json_schema_extra={"jsonpath": "$.meta.estimate_sum"})
    total_num: int = Field(json_schema_extra={"jsonpath": "$.meta.sum"})
    song: list[SongSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_song"},
    )
    singer: list[SingerSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.singer"},
    )
    album: list[AlbumSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_album"},
    )
    songlist: list[SongListSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_songlist"},
    )
    user: list[dict[str, Any]] = Field(
        json_schema_extra={"jsonpath": "$.body.item_user"},
    )
    audio_alum: list[AlbumSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_audio"},
    )
    mv: list[MvSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_mv"},
    )


class GeneralSearchResponse(Response):
    """综合搜索响应模型.

    每个分类字段都是独立的结果容器,既给出当前已返回的数据,也保留该分类继续翻页所需的上下文.

    Attributes:
        searchid: 搜索会话 ID,用于后续相关请求.
        perpage: 每页结果数量.
        nextpage: 下一页页码,-1 表示已加载全部结果.
        nextpage_start: 综合搜索继续翻页的关键参数.
        song: 单曲结果容器.
        singer: 歌手结果容器.
        album: 专辑结果容器.
        mv: MV 结果容器.
        songlist: 歌单结果容器.
        audio: 节目结果容器.
        direct: 直接命中结果分组.
        related: 相关搜索词推荐结果容器.
    """

    searchid: str = Field(json_schema_extra={"jsonpath": "$.meta.sid"})
    perpage: int = Field(json_schema_extra={"jsonpath": "$.meta.perpage"})
    nextpage: int = Field(json_schema_extra={"jsonpath": "$.meta.nextpage"})
    nextpage_start: dict[str, Any] = Field(
        json_schema_extra={"jsonpath": "$.meta.nextpage_start"},
    )
    song: GeneralSearchRequestBody[SongSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_song"},
    )
    singer: GeneralSearchRequestBody[SingerSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.singer"},
    )
    mv: GeneralSearchRequestBody[MvSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_mv"},
    )
    album: GeneralSearchRequestBody[AlbumSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_album"},
    )
    songlist: GeneralSearchRequestBody[SongListSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_songlist"},
    )
    audio: GeneralSearchRequestBody[AlbumSearch] = Field(
        json_schema_extra={"jsonpath": "$.body.item_audio"},
    )
    direct: list[dict[str, Any]] = Field(
        default_factory=list,
        json_schema_extra={"jsonpath": "$.body.direct_result.direct_group"},
    )
    related: GeneralSearchRequestBody[RelatedSearchWord] = Field(
        json_schema_extra={"jsonpath": "$.body.item_related"},
    )
