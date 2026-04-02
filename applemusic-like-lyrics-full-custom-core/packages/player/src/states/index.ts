import { atom } from "jotai";
import { invoke } from "@tauri-apps/api/core";
import { darkModeAtom, DarkMode, autoDarkModeAtom } from "./appAtoms";
import {
	smtcShuffleStateAtom,
	smtcRepeatModeAtom,
	RepeatMode,
} from "./smtcAtoms";

export const isDarkThemeAtom = atom(
	(get) => {
		const mode = get(darkModeAtom);
		if (mode === DarkMode.Auto) {
			return get(autoDarkModeAtom);
		}
		return mode === DarkMode.Dark;
	},
	(_get, set, newIsDark: boolean) => {
		const newMode = newIsDark ? DarkMode.Dark : DarkMode.Light;
		set(darkModeAtom, newMode);
	},
);

export const onClickSmtcShuffleAtom = atom(null, (get) => {
	const currentShuffle = get(smtcShuffleStateAtom);
	invoke("control_external_media", {
		payload: {
			type: "setShuffle",
			is_active: !currentShuffle,
		},
	}).catch(console.error);
});

export const onClickSmtcRepeatAtom = atom(null, (get) => {
	const currentMode = get(smtcRepeatModeAtom);
	let nextMode: RepeatMode;
	switch (currentMode) {
		case RepeatMode.Off:
			nextMode = RepeatMode.All;
			break;
		case RepeatMode.All:
			nextMode = RepeatMode.One;
			break;
		case RepeatMode.One:
			nextMode = RepeatMode.Off;
			break;
		default:
			nextMode = RepeatMode.Off;
	}
	invoke("control_external_media", {
		payload: {
			type: "setRepeatMode",
			mode: nextMode,
		},
	}).catch(console.error);
});
