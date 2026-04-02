import { PlayIcon } from "@radix-ui/react-icons";
import { Avatar, Box, Flex, type FlexProps, Inset } from "@radix-ui/themes";
import { useAtomValue } from "jotai";
import {
	type FC,
	type HTMLProps,
	useEffect,
	useLayoutEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { Trans } from "react-i18next";
import { useVirtualizer } from "@tanstack/react-virtual";
import { db, type Song } from "../../dexie.ts";
import { type SongData, emitAudioThread } from "../../utils/player.ts";
import styles from "./index.module.css";
import {
	currentPlaylistMusicIndexAtom,
	currentPlaylistAtom,
} from "@applemusic-like-lyrics/react-full";

const PlaylistSongItem: FC<
	{
		songData: SongData;
		index: number;
	} & HTMLProps<HTMLDivElement>
> = ({ songData, className, index, ...props }) => {
	const playlistIndex = useAtomValue(currentPlaylistMusicIndexAtom);
	const [cover, setCover] = useState("");

	const song: Song | null = useMemo(() => {
		if (songData.type === "custom" && songData.songJsonData) {
			try {
				return JSON.parse(songData.songJsonData);
			} catch (e) {
				console.error("Failed to parse songJsonData:", e);
				return null;
			}
		}
		return null;
	}, [songData]);

	useLayoutEffect(() => {
		let newUri: string | null = null;
		let isActive = true;

		if (song) {
			db.songs.get(song.id).then((dbSong) => {
				if (isActive && dbSong?.cover instanceof Blob) {
					newUri = URL.createObjectURL(dbSong.cover);
					setCover(newUri);
				}
			});
		} else {
			setCover("");
		}

		return () => {
			isActive = false;
			if (newUri) {
				URL.revokeObjectURL(newUri);
			}
		};
	}, [song]);

	const name =
		song?.songName ??
		(songData.type === "local" ? songData.filePath : "未知歌曲");
	const artists = song?.songArtists ?? "未知艺术家";

	return (
		<div className={className} {...props}>
			<button
				type="button"
				className={styles.playlistSongItem}
				onDoubleClick={() => {
					emitAudioThread("jumpToSong", {
						songIndex: index,
					});
				}}
				aria-label={`播放 ${name} - ${artists}`}
			>
				<Avatar size="4" fallback={<div />} src={cover} />
				<div className={styles.musicInfo}>
					<div className={styles.name}>{name}</div>
					<div className={styles.artists}>{artists}</div>
				</div>
				{playlistIndex === index && <PlayIcon />}
			</button>
		</div>
	);
};

export const NowPlaylistCard: FC<FlexProps> = (props) => {
	const playlist = useAtomValue(currentPlaylistAtom);
	const playlistIndex = useAtomValue(currentPlaylistMusicIndexAtom);
	const playlistContainerRef = useRef<HTMLDivElement>(null);

	const rowVirtualizer = useVirtualizer({
		count: playlist.length,
		getScrollElement: () => playlistContainerRef.current,
		estimateSize: () => 55,
		overscan: 5,
	});

	useEffect(() => {
		if (rowVirtualizer) {
			rowVirtualizer.scrollToIndex(playlistIndex, { align: "center" });
		}
	}, [playlistIndex, rowVirtualizer]);

	return (
		<Flex
			direction="column"
			maxWidth="400px"
			maxHeight="500px"
			style={{
				height: "50vh",
				width: "max(10vw, 50vh)",
				backdropFilter: "blur(1em)",
				backgroundColor: "var(--black-a8)",
			}}
			{...props}
		>
			<Box py="3" px="4">
				<Trans i18nKey="playbar.playlist.title">当前播放列表</Trans>
			</Box>
			<Inset
				clip="padding-box"
				side="bottom"
				pb="current"
				style={{ overflowY: "auto" }}
				ref={playlistContainerRef}
			>
				<div
					style={{
						height: `${rowVirtualizer.getTotalSize()}px`,
						width: "100%",
						position: "relative",
					}}
				>
					{rowVirtualizer.getVirtualItems().map((virtualItem) => {
						const songData = playlist[virtualItem.index];
						if (!songData) return null;
						return (
							<PlaylistSongItem
								key={virtualItem.key}
								style={{
									position: "absolute",
									top: 0,
									left: 0,
									width: "100%",
									height: `${virtualItem.size}px`,
									transform: `translateY(${virtualItem.start}px)`,
								}}
								songData={songData}
								index={virtualItem.index}
							/>
						);
					})}
				</div>
			</Inset>
		</Flex>
	);
};
