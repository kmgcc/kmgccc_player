import { useLayoutEffect, useState } from "react";
import { type Song, db } from "../dexie.ts";
import { getVideoThumbnail } from "./video-thumbnail.ts";

export const useSongCover = (song?: Song) => {
	const [songImgUrl, setSongImgUrl] = useState<string>("");

	useLayoutEffect(() => {
		if (song?.cover) {
			if (song.cover.type.startsWith("image") || song.cachedThumbnail) {
				const newUri = URL.createObjectURL(song.cachedThumbnail || song.cover);
				setSongImgUrl(newUri);
				return () => {
					URL.revokeObjectURL(newUri);
				};
			}
			if (song.cover.type.startsWith("video")) {
				const promise = getVideoThumbnail(song.cover).then((blob) => {
					const newUri = URL.createObjectURL(blob);
					db.songs.update(song.id, (newSong) => {
						newSong.cachedThumbnail = blob;
					});
					setSongImgUrl(newUri);
					return newUri;
				});
				return () => {
					promise.then((uri) => {
						URL.revokeObjectURL(uri);
					});
				};
			}
			setSongImgUrl("");
		}
	}, [song]);

	return songImgUrl;
};
