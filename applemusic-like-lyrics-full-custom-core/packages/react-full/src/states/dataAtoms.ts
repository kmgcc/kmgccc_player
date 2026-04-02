import { atom } from "jotai";
import { atomWithStorage } from "jotai/utils";
import type { LyricLine } from "@applemusic-like-lyrics/lyric";

// ==================================================================
//                            类型定义
// ==================================================================

/**
 * 定义了播放列表中歌曲的数据结构。
 * - `local`: 代表本地文件歌曲。
 * - `custom`: 代表通过自定义数据源（如API）获取的歌曲。
 */
export type SongData =
	| { type: "local"; filePath: string; origOrder: number }
	| { type: "custom"; id: string; songJsonData: string; origOrder: number };

/**
 * 定义了艺术家信息的标准结构。
 */
export interface ArtistStateEntry {
	name: string;
	id: string;
}

/**
 * 定义了音频质量的类型枚举。
 */
export enum AudioQualityType {
	None = "none",
	Standard = "standard",
	Lossless = "lossless",
	HiResLossless = "hi-res-lossless",
	DolbyAtmos = "dolby-atmos",
}

/**
 * 定义了描述音频质量完整信息的接口。
 */
export interface MusicQualityState {
	type: AudioQualityType;
	codec: string;
	channels: number;
	sampleRate: number;
	sampleFormat: string;
}

// ==================================================================
//                        音乐核心数据原子状态
// ==================================================================

/**
 * 当前播放歌曲的唯一标识符。
 * @type {string}
 */
export const musicIdAtom = atom("");

/**
 * 当前播放的音乐名称。
 * 将会显示在专辑图下方（横向布局）或专辑图右侧（竖向布局）。
 * @type {string}
 * @default "未知歌曲"
 */
export const musicNameAtom = atom("未知歌曲");

/**
 * 当前播放的音乐创作者列表。
 * 会显示在音乐名称下方。
 * @type {ArtistStateEntry[]}
 */
export const musicArtistsAtom = atom<ArtistStateEntry[]>([
	{ name: "未知创作者", id: "unknown" },
]);

/**
 * 当前播放的音乐所属专辑名称。
 * 会显示在音乐名称/创作者下方。
 * @type {string}
 * @default "未知专辑"
 */
export const musicAlbumNameAtom = atom("未知专辑");

/**
 * 当前播放的音乐专辑封面 URL。
 * 除了图片也可以是视频资源。
 * @type {string}
 */
export const musicCoverAtom = atom("");

/**
 * 用于快速比较封面是否变化的哈希值。
 * @type {number | null}
 */
export const musicCoverHashAtom = atom<number | null>(null);

/**
 * 当前播放的音乐专辑封面资源是否为视频。
 * @type {boolean}
 */
export const musicCoverIsVideoAtom = atom(false);

/**
 * 当前音乐的总时长，单位为毫秒。
 * @type {number}
 */
export const musicDurationAtom = atom(0);

/**
 * 当前音乐是否正在播放。
 * @type {boolean}
 */
export const musicPlayingAtom = atom(false);

/**
 * 当前音乐的播放进度，单位为毫秒。
 * @type {number}
 */
export const musicPlayingPositionAtom = atom(0);

/**
 * 当前播放的音乐音量大小，范围在 [0.0-1.0] 之间。
 * 本状态将会保存在 localStorage 中，以便跨会话保持音量设置。
 * @type {number}
 */
export const musicVolumeAtom = atomWithStorage(
	"amll-react-full.musicVolumeAtom",
	0.5,
);

/**
 * 当前播放的音乐的歌词行数据。
 * @type {LyricLine[]}
 */
export const musicLyricLinesAtom = atom<LyricLine[]>([]);

/**
 * 当前音乐的音质信息对象。
 * @type {MusicQualityState}
 */
export const musicQualityAtom = atom<MusicQualityState>({
	type: AudioQualityType.None,
	codec: "unknown",
	channels: 2,
	sampleRate: 44100,
	sampleFormat: "s16",
});

/**
 * 根据音质信息生成的、用于UI展示的标签内容。
 * 如果为 null，则不显示标签。
 * @type {{ tagIcon: boolean; tagText: string; isDolbyAtmos: boolean; } | null}
 */
export const musicQualityTagAtom = atom<{
	tagIcon: boolean;
	tagText: string;
	isDolbyAtmos: boolean;
} | null>(null);

/**
 * 当前的播放列表。
 * @type {SongData[]}
 */
export const currentPlaylistAtom = atom<SongData[]>([]);

/**
 * 当前歌曲在播放列表中的索引。
 * @type {number}
 */
export const currentPlaylistMusicIndexAtom = atom(0);

// ==================================================================
//                        音频可视化相关原子状态
// ==================================================================

/**
 * 用于音频可视化频谱图的实时频域数据。
 * @type {number[]}
 */
export const fftDataAtom = atom<number[]>([]);

/**
 * 代表低频部分的音量大小，用于背景脉动等效果。
 * 取值范围建议在 [0.0-1.0] 之间。
 * @type {number}
 */
export const lowFreqVolumeAtom = atom<number>(1);
