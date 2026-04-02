import {
	isLyricPageOpenedAtom,
	musicIdAtom,
	PrebuiltLyricPlayer,
} from "@applemusic-like-lyrics/react-full";
import { ContextMenu } from "@radix-ui/themes";
import classnames from "classnames";
import { useAtomValue } from "jotai";
import { type FC, useLayoutEffect } from "react";

import { AMLLContextMenuContent } from "../AMLLContextMenu/index.tsx";
import { AudioQualityDialog } from "../AudioQualityDialog/index.tsx";
import styles from "./index.module.css";
import { RecordPanel } from "../RecordPanel/index.tsx";

export const AMLLWrapper: FC = () => {
	const isLyricPageOpened = useAtomValue(isLyricPageOpenedAtom);
	const musicId = useAtomValue(musicIdAtom);

	useLayoutEffect(() => {
		if (isLyricPageOpened) {
			document.body.dataset.amllLyricsOpen = "";
		} else {
			delete document.body.dataset.amllLyricsOpen;
		}
	}, [isLyricPageOpened]);

	return (
		<>
			<ContextMenu.Root>
				<ContextMenu.Trigger>
					<PrebuiltLyricPlayer
						key={musicId}
						id="amll-lyric-player"
						className={classnames(
							styles.lyricPage,
							isLyricPageOpened && styles.opened,
						)}
					/>
				</ContextMenu.Trigger>
				<AMLLContextMenuContent />
			</ContextMenu.Root>
			<AudioQualityDialog />
			<RecordPanel />
		</>
	);
};

export default AMLLWrapper;
