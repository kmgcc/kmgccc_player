import { getCurrentWindow } from "@tauri-apps/api/window";
import { useSetAtom } from "jotai";
import { type FC, useEffect } from "react";
import { autoDarkModeAtom } from "../../states/appAtoms";

export const DarkThemeDetector: FC = () => {
	const setAutoDarkMode = useSetAtom(autoDarkModeAtom);

	useEffect(() => {
		const appWindow = getCurrentWindow();
		let unlisten: (() => void) | undefined;

		const setupListener = async () => {
			try {
				const initialTheme = await appWindow.theme();
				setAutoDarkMode(initialTheme === "dark");
			} catch (e) {
				console.error("获取当前的系统主题失败，设置为浅色主题", e);
				setAutoDarkMode(false);
			}

			unlisten = await appWindow.onThemeChanged(({ payload: theme }) => {
				setAutoDarkMode(theme === "dark");
			});
		};

		setupListener();

		return () => {
			unlisten?.();
		};
	}, [setAutoDarkMode]);

	return null;
};
