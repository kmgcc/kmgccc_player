import { DomLyricPlayer } from "./dom/index.ts";

export { LyricPlayerBase } from "./base.ts";
export * from "./canvas/index.ts";
export * from "./dom-slim/index.ts";
export * from "./dom/index.ts";

/**
 * 歌词中不雅用语的掩码模式
 */
enum MaskObsceneWordsMode {
	/** 禁用任何不雅用语掩码 */
	Disabled = "",
	/** 完全掩码所有不雅用语 */
	FullMask = "full-mask",
	// TODO: 更多模式
}

export {
	MaskObsceneWordsMode,
	/**
	 * 默认导出的歌词播放组件
	 */
	DomLyricPlayer as LyricPlayer,
};
