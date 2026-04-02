import { HamburgerMenuIcon, MagnifyingGlassIcon } from "@radix-ui/react-icons";
import {
	Badge,
	Box,
	DropdownMenu,
	Flex,
	Heading,
	IconButton,
	Spinner,
	Text,
} from "@radix-ui/themes";
import { useVirtualizer } from "@tanstack/react-virtual";
import { platform } from "@tauri-apps/plugin-os";
import { useLiveQuery } from "dexie-react-hooks";
import { useAtom, useAtomValue } from "jotai";
import { type FC, useEffect, useRef, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { ExtensionInjectPoint } from "../../components/ExtensionInjectPoint/index.tsx";
import { NewPlaylistButton } from "../../components/NewPlaylistButton/index.tsx";
import { PageContainer } from "../../components/PageContainer/index.tsx";
import { PlaylistCard } from "../../components/PlaylistCard/index.tsx";
import { db } from "../../dexie.ts";
import { router } from "../../router.tsx";
import {
	updateInfoAtom,
	musicContextModeAtom,
	MusicContextMode,
} from "../../states/appAtoms.ts";

export const Component: FC = () => {
	const playlists = useLiveQuery(() => db.playlists.toArray());
	const updateInfo = useAtomValue(updateInfoAtom);
	const parentRef = useRef<HTMLDivElement>(null);

	const [musicContextMode, setMusicContextMode] = useAtom(musicContextModeAtom);
	const [currentPlatform, setCurrentPlatform] = useState<string>("");
	const { t } = useTranslation();

	useEffect(() => {
		setCurrentPlatform(platform());
	}, []);

	const rowVirtualizer = useVirtualizer({
		count: playlists?.length ?? 0,
		getScrollElement: () => parentRef.current,
		estimateSize: () => 105,
		overscan: 5,
	});

	const isSystemListenerMode =
		musicContextMode === MusicContextMode.SystemListener;

	return (
		<PageContainer>
			<Flex direction="column" height="100%">
				<Flex direction="row" align="center" wrap="wrap" mt="5">
					<Box asChild flexGrow="1">
						<Heading wrap="nowrap" my="4">
							AMLL Player
							{updateInfo && (
								<Badge
									onClick={() => router.navigate("/settings#updater")}
									radius="full"
									style={{
										cursor: "pointer",
									}}
									color="indigo"
									ml="2"
								>
									<Trans i18nKey="page.main.updateAvailableTag">
										有可用更新
									</Trans>
								</Badge>
							)}
							{isSystemListenerMode && (
								<Badge
									radius="full"
									style={{ cursor: "pointer" }}
									color="green"
									ml="2"
									onClick={() => router.navigate("/settings#player")}
								>
									{t("page.main.menu.systemListenerActive")}
								</Badge>
							)}
						</Heading>
					</Box>
					<Flex gap="1" wrap="wrap">
						<ExtensionInjectPoint injectPointName="page.main.sidebar.before" />
						<IconButton variant="soft" asChild>
							<Link to="/search">
								<MagnifyingGlassIcon />
							</Link>
						</IconButton>
						<NewPlaylistButton />
						<DropdownMenu.Root>
							<DropdownMenu.Trigger>
								<IconButton variant="soft">
									<HamburgerMenuIcon />
								</IconButton>
							</DropdownMenu.Trigger>
							<DropdownMenu.Content>
								<ExtensionInjectPoint injectPointName="page.main.menu.top" />

								{currentPlatform === "windows" && (
									<DropdownMenu.Item
										color={isSystemListenerMode ? "green" : undefined}
										onClick={() => {
											setMusicContextMode(
												isSystemListenerMode
													? MusicContextMode.Local // 如果已是监听模式，则切换回本地模式
													: MusicContextMode.SystemListener, // 否则，切换到监听模式
											);
										}}
									>
										{isSystemListenerMode
											? t("page.main.menu.exitSystemListenerMode")
											: t("page.main.menu.enterSystemListenerMode")}
									</DropdownMenu.Item>
								)}
								{currentPlatform === "windows" && <DropdownMenu.Separator />}

								<DropdownMenu.Sub>
									<DropdownMenu.SubTrigger>
										<Trans i18nKey="page.main.menu.enterWSProtocolMode">
											进入 WS Protocol 模式
										</Trans>
									</DropdownMenu.SubTrigger>
									<DropdownMenu.SubContent>
										<DropdownMenu.Item asChild>
											<Link to="/ws/recv">
												<Trans i18nKey="page.main.menu.asWSProtocolReceiver">
													作为状态接收者
												</Trans>
											</Link>
										</DropdownMenu.Item>
										<DropdownMenu.Item disabled>
											<Trans i18nKey="page.main.menu.asWSProtocolSenderWIP">
												作为状态发送者（施工中）
											</Trans>
										</DropdownMenu.Item>
									</DropdownMenu.SubContent>
								</DropdownMenu.Sub>
								<DropdownMenu.Item asChild>
									<Link to="/settings">
										<Trans i18nKey="page.main.menu.settings">设置</Trans>
									</Link>
								</DropdownMenu.Item>
								<ExtensionInjectPoint injectPointName="page.main.menu.bottom" />
							</DropdownMenu.Content>
						</DropdownMenu.Root>
						<ExtensionInjectPoint injectPointName="page.main.sidebar.after" />
					</Flex>
				</Flex>

				<ExtensionInjectPoint injectPointName="page.main.top" />

				{playlists !== undefined ? (
					playlists.length === 0 ? (
						<Text mt="9" as="div" align="center">
							<Trans i18nKey="page.main.noPlaylistTip">
								没有播放列表，快去新建一个吧！
							</Trans>
						</Text>
					) : (
						<div
							style={{
								overflowY: "auto",
								minHeight: "0",
							}}
							ref={parentRef}
						>
							<div
								style={{
									height: `${rowVirtualizer.getTotalSize()}px`,
									width: "100%",
									position: "relative",
								}}
							>
								{rowVirtualizer.getVirtualItems().map((virtualItem) => {
									const playlist = playlists[virtualItem.index];
									return (
										<div
											key={virtualItem.key}
											style={{
												position: "absolute",
												top: 0,
												left: 0,
												width: "100%",
												padding: "4px 8px",
												height: `${virtualItem.size}px`,
												transform: `translateY(${virtualItem.start}px)`,
												boxSizing: "border-box",
											}}
										>
											<PlaylistCard playlist={playlist} />
										</div>
									);
								})}
							</div>
						</div>
					)
				) : (
					<Flex
						direction="column"
						gap="2"
						justify="center"
						align="center"
						height="70vh"
					>
						<Spinner size="3" />
						<Trans i18nKey="page.main.loadingPlaylist">加载歌单中</Trans>
					</Flex>
				)}
				<ExtensionInjectPoint injectPointName="page.main.bottom" />
			</Flex>
		</PageContainer>
	);
};

Component.displayName = "MainPage";

export default Component;
