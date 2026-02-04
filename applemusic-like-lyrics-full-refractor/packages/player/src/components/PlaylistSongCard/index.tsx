import { toDuration } from "@applemusic-like-lyrics/react-full";
import { HamburgerMenuIcon, PlayIcon } from "@radix-ui/react-icons";
import {
	Avatar,
	Box,
	Card,
	DropdownMenu,
	Flex,
	IconButton,
	Skeleton,
	Text,
} from "@radix-ui/themes";
import { useLiveQuery } from "dexie-react-hooks";
import type { Loadable } from "jotai/vanilla/utils/loadable";
import { type CSSProperties, forwardRef } from "react";
import { Trans, useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { type Song, db } from "../../dexie.ts";
import { router } from "../../router.tsx";
import { useSongCover } from "../../utils/use-song-cover.ts";

export const PlaylistSongCard = forwardRef<
	HTMLDivElement,
	{
		songId: string;
		songIndex: number;
		onPlayList: (songIndex: number) => void;
		onDeleteSong: (songId: string) => void;
		style?: CSSProperties;
	}
>(({ songId, songIndex, onPlayList, onDeleteSong, style }, ref) => {
	const song: Loadable<Song> = useLiveQuery(
		() =>
			db.songs.get(songId).then((data) => {
				if (!data) {
					return {
						state: "hasError",
						error: new Error(`未找到歌曲 ID ${songId}`),
					};
				}
				return {
					state: "hasData",
					data: data,
				};
			}),
		[songId],
		{
			state: "loading",
		},
	);
	const songImgUrl = useSongCover(
		song.state === "hasData" ? song.data : undefined,
	);
	const { t } = useTranslation();
	const navigate = useNavigate();

	return (
		<Skeleton
			style={style}
			key={`song-card-${songId}`}
			loading={song.state === "loading"}
			ref={ref}
			onDoubleClick={() => onPlayList(songIndex)}
		>
			<Box py="1" style={style}>
				<Card>
					<Flex p="1" align="center" gap="4">
						<Avatar size="5" fallback={<div />} src={songImgUrl} />
						<Flex direction="column" justify="center" flexGrow="1" minWidth="0">
							<Text wrap="nowrap" truncate>
								{song.state === "hasData" &&
									(song.data.songName ||
										song.data.filePath ||
										t(
											"page.playlist.music.unknownSongName",
											"未知歌曲 ID {id}",
											{
												id: songId,
											},
										))}
							</Text>
							<Text wrap="nowrap" truncate color="gray">
								{song.state === "hasData" && (song.data.songArtists || "")}
							</Text>
						</Flex>
						<Text wrap="nowrap">
							{song.state === "hasData" &&
								(song.data.duration ? toDuration(song.data.duration) : "")}
						</Text>
						<IconButton variant="ghost" onClick={() => onPlayList(songIndex)}>
							<PlayIcon />
						</IconButton>
						<DropdownMenu.Root>
							<DropdownMenu.Trigger>
								<IconButton
									variant="ghost"
									onClick={() => router.navigate(`/song/${songId}`)}
								>
									<HamburgerMenuIcon />
								</IconButton>
							</DropdownMenu.Trigger>
							<DropdownMenu.Content>
								<DropdownMenu.Item onClick={() => onPlayList(songIndex)}>
									<Trans i18nKey="page.playlist.music.dropdown.playMusic">
										播放音乐
									</Trans>
								</DropdownMenu.Item>
								<DropdownMenu.Item onClick={() => navigate(`/song/${songId}`)}>
									<Trans i18nKey="page.playlist.music.dropdown.editMusicOverrideData">
										编辑歌曲覆盖信息
									</Trans>
								</DropdownMenu.Item>
								<DropdownMenu.Separator />
								<DropdownMenu.Item
									color="red"
									onClick={() => onDeleteSong(songId)}
								>
									<Trans i18nKey="page.playlist.music.dropdown.removeFromPlaylist">
										从歌单中删除
									</Trans>
								</DropdownMenu.Item>
							</DropdownMenu.Content>
						</DropdownMenu.Root>
					</Flex>
				</Card>
			</Box>
		</Skeleton>
	);
});
