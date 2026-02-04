import { Theme, Flex, Tabs } from "@radix-ui/themes";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { platform, version } from "@tauri-apps/plugin-os";
import { StrictMode, useEffect, useState } from "react";
import { ToastContainer } from "react-toastify";
import semverGt from "semver/functions/gt";
import styles from "./index.module.css";
import { useAtomValue } from "jotai";
import "@radix-ui/themes/styles.css";
import LosslessScreenshotTab from "./LosslessScreenshotTab";
import RecordTab from "./RecordTab";
import { isDarkThemeAtom } from "../../states/appAtoms";

export const ScreenshotApp = () => {
	const isDarkTheme = useAtomValue(isDarkThemeAtom);
	const [hasBackground, setHasBackground] = useState(false);

	useEffect(() => {
		(async () => {
			const win = getCurrentWindow();
			if (platform() === "windows") {
				if (semverGt("10.0.22000", version())) {
					setHasBackground(true);
					await win.clearEffects();
				}
			}
			await new Promise((r) => requestAnimationFrame(r));

			await win.show();
		})();
	}, []);

	useEffect(() => {
		(async () => {
			const win = getCurrentWindow();
			if (isDarkTheme) {
				await win.setTheme("dark");
			} else {
				await win.setTheme("light");
			}
		})();
	}, [isDarkTheme]);

	return (
		<StrictMode>
			<Theme
				appearance={isDarkTheme ? "dark" : "light"}
				panelBackground="solid"
				hasBackground={hasBackground}
				className={styles.radixTheme}
			>
				<Flex
					gap="2"
					px="4"
					pt="8"
					pb="4"
					overflow="hidden"
					style={{
						height: "100vh",
					}}
					direction="column"
				>
					<Tabs.Root
						style={{
							flexGrow: 1,
							overflow: "hidden",
							display: "flex",
							flexDirection: "column",
						}}
						defaultValue="webview2-devtool-screenshot"
					>
						<Tabs.List
							style={{
								flexShrink: 0,
							}}
						>
							<Tabs.Trigger value="webview2-devtool-screenshot">
								无损截图模式
							</Tabs.Trigger>
							{/* <Tabs.Trigger value="record">
                                有损录制模式
                            </Tabs.Trigger> */}
						</Tabs.List>
						<Tabs.Content
							style={{
								flexGrow: 1,
								overflow: "hidden",
							}}
							value="webview2-devtool-screenshot"
						>
							<LosslessScreenshotTab />
						</Tabs.Content>
						<Tabs.Content
							style={{
								flexGrow: 1,
								overflow: "hidden",
							}}
							value="record"
						>
							<RecordTab />
						</Tabs.Content>
					</Tabs.Root>
				</Flex>
				<ToastContainer
					theme="dark"
					position="bottom-right"
					style={{
						marginBottom: "150px",
					}}
				/>
			</Theme>
		</StrictMode>
	);
};
