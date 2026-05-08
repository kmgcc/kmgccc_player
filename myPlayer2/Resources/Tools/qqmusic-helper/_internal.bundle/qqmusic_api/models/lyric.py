"""Lyric API 返回模型定义."""

from pydantic import Field

from ..algorithms import qrc_decrypt
from .request import Response


class GetLyricResponse(Response):
    """歌词接口返回的原始歌词载荷.

    Attributes:
        song_id: 歌曲 ID.
        crypt: 是否需要按当前模型约定进行解密.
        lyric: 原始歌词内容.
        trans: 翻译歌词内容.
        roma: 罗马音歌词内容.
    """

    song_id: int = Field(alias="songID")
    crypt: int
    lyric: str
    trans: str = ""
    roma: str = ""

    def decrypt(self) -> "GetLyricResponse":
        """返回一个歌词内容已按需解密的响应对象.

        Returns:
            GetLyricResponse: 当 `crypt == 1` 时, 返回一个复制后的响应对象, 并将 `lyric`、`trans`、`roma` 替换为解密文本. 否则直接返回当前实例. 该方法不会原地修改当前对象字段.
        """
        if self.crypt != 1:
            return self

        return self.model_copy(
            update={
                "lyric": qrc_decrypt(self.lyric) if self.lyric else "",
                "trans": qrc_decrypt(self.trans) if self.trans else "",
                "roma": qrc_decrypt(self.roma) if self.roma else "",
            },
        )
