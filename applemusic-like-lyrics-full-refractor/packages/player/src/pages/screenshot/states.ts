import { atom } from "jotai";
import { atomWithStorage } from "jotai/utils";

export const resizeWindowAtom = atomWithStorage(
	"screenshot.resizeWindow",
	true,
);
export const targetWidthAtom = atomWithStorage("screenshot.targetWidth", 1920);
export const targetHeightAtom = atomWithStorage(
	"screenshot.targetHeight",
	1080,
);
export const recoverWindowSizeAtom = atomWithStorage(
	"screenshot.recoverWindowSize",
	true,
);
export const recordMediaStreamAtom = atom(undefined as MediaStream | undefined);
