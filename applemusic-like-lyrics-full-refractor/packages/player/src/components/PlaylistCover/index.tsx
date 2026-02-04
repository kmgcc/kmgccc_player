import classNames from "classnames";
import { useLiveQuery } from "dexie-react-hooks";
import { type FC, type HTMLProps, useEffect, useState } from "react";
import { db } from "../../dexie.ts";
import styles from "./index.module.css";

export const PlaylistCover: FC<
	{
		playlistId: number;
	} & HTMLProps<HTMLDivElement>
> = ({ playlistId, className, ...props }) => {
	const [playlistImgs, setPlaylistImgs] = useState([] as string[]);

	const playlist = useLiveQuery(
		() => db.playlists.get(playlistId),
		[playlistId],
	);

	const firstFourSongs = useLiveQuery(async () => {
		if (playlist && !playlist.playlistCover) {
			const result = [];
			for (const songId of playlist.songIds) {
				const song = await db.songs.get(songId);
				if (song?.cover.type.startsWith("image") && song.cover.size > 0) {
					result.push(song);
					if (result.length === 4) break;
				}
			}
			return result;
		}
		return [];
	}, [playlist]);

	useEffect(() => {
		if (playlist?.playlistCover) {
			const coverUrl = URL.createObjectURL(playlist.playlistCover);

			setPlaylistImgs([coverUrl]);

			return () => {
				URL.revokeObjectURL(coverUrl);
			};
		}
		if (firstFourSongs) {
			const imgs = firstFourSongs.map((v) => URL.createObjectURL(v.cover));

			setPlaylistImgs(imgs);

			return () => {
				for (const img of imgs) {
					URL.revokeObjectURL(img);
				}
			};
		}
	}, [firstFourSongs, playlist]);

	return (
		<div
			className={classNames(styles.playlistCover, "img-border", className)}
			{...props}
		>
			{playlistImgs.map((img) => (
				<div
					key={img}
					style={{
						backgroundImage: `url(${img})`,
					}}
				/>
			))}
		</div>
	);
};
