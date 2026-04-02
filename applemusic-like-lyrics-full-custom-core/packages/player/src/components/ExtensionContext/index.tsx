import * as lyric from "@applemusic-like-lyrics/lyric";
import * as amllStates from "@applemusic-like-lyrics/react-full";
import * as appAtoms from "../../states/appAtoms";
import * as smtcAtoms from "../../states/smtcAtoms";
import * as extensionsAtoms from "../../states/extensionsAtoms";

import * as http from "@tauri-apps/plugin-http";
import chalk from "chalk";
import { useAtomValue, useSetAtom, useStore } from "jotai";
import { type FC, useCallback, useEffect, useMemo, useRef } from "react";
import type * as JSXRuntime from "react/jsx-runtime";
import { useTranslation } from "react-i18next";
import { uid } from "uid";
import { db } from "../../dexie.ts";
import { PlayerExtensionContext, sourceMapOffsetLines } from "./ext-ctx.ts";
import { extensionMetaAtom } from "../../states/extension.ts";
import { ExtensionLoadResult } from "../../states/extensionsAtoms.ts";
import type {
	ExtensionMetaState,
	LoadedExtension,
} from "../../states/extensionsAtoms.ts";

const AsyncFunction: FunctionConstructor = Object.getPrototypeOf(
	async () => {},
).constructor;

declare global {
	interface Window {
		React: typeof React;
		ReactDOM: typeof ReactDOM;
		Jotai: typeof Jotai;
		RadixTheme: typeof RadixTheme;
		JSXRuntime: typeof JSXRuntime;
	}
}

class Notify {
	promise: Promise<void>;
	resolve: () => void;
	reject: (err: Error) => void;
	constructor() {
		let resolve: () => void = () => {};
		let reject: (err: Error) => void = () => {};
		const p = new Promise<void>((res, rej) => {
			resolve = res;
			reject = rej;
		});
		this.promise = p;
		this.resolve = resolve;
		this.reject = reject;
	}

	wait() {
		return this.promise;
	}

	notify() {
		this.resolve();
	}
}

const LOG_TAG = chalk.bgHex("#00AAFF").hex("#FFFFFF")(" EXTENSION ");

const SingleExtensionContext: FC<{
	extensionMeta: ExtensionMetaState;
	waitForDependency: (extensionId: string) => Promise<void>;
	extPromise: readonly [Promise<void>, () => void, (err: Error) => void];
}> = ({ extensionMeta, waitForDependency, extPromise }) => {
	const store = useStore();
	const { i18n } = useTranslation();
	const cancelRef = useRef<Notify | undefined>(undefined);
	const setLoadedExtension = useSetAtom(extensionsAtoms.loadedExtensionAtom);
	useEffect(() => {
		let canceled = false;
		const extI18n = i18n.cloneInstance({
			ns: extensionMeta.id,
		});

		const playerStatesObject = Object.freeze({
			...appAtoms,
			...smtcAtoms,
			...extensionsAtoms,
		});

		const context = new PlayerExtensionContext(
			playerStatesObject,
			Object.freeze({ ...amllStates }),
			extI18n,
			store,
			extensionMeta,
			lyric,
			db,
			http,
		);

		const loadedExt: LoadedExtension = {
			extensionFunc: async () => {},
			extensionMeta,
			context,
		};

		(async () => {
			const [React, ReactDOM, Jotai, RadixTheme, JSXRuntime] =
				await Promise.all([
					import("react"),
					import("react-dom"),
					import("jotai"),
					import("@radix-ui/themes"),
					import("react/jsx-runtime"),
				]);
			window.React = React;
			window.ReactDOM = ReactDOM;
			window.Jotai = Jotai;
			window.RadixTheme = RadixTheme;
			window.JSXRuntime = JSXRuntime;

			const cancelNotify = cancelRef.current;
			if (cancelNotify) {
				await cancelNotify.wait();
			}
			if (canceled) return;
			console.log(
				LOG_TAG,
				"正在加载扩展程序",
				extensionMeta.id,
				extensionMeta.fileName,
			);
			const genFuncName = () => `__amll_internal_${uid()}`;
			const resolveFuncName = genFuncName();
			const rejectFuncName = genFuncName();
			const waitForDependencyFuncName = genFuncName();
			const wrapperScript: string[] = [];
			wrapperScript.push('"use strict";');
			wrapperScript.push("try {");

			for (const dependencyId of extensionMeta.dependency) {
				wrapperScript.push(
					`await ${waitForDependencyFuncName}(${JSON.stringify(dependencyId)})`,
				);
			}

			let comment = "";
			const offsetLines = wrapperScript.length + 2;

			try {
				// 修正源映射表的行数，方便调试
				const [code, sourceMapComment] = await sourceMapOffsetLines(
					extensionMeta.scriptData,
					extensionMeta.id,
					offsetLines,
				);
				if (canceled) return;
				wrapperScript.push(code);
				comment = sourceMapComment;
			} catch (err) {
				console.log(
					LOG_TAG,
					"无法转换源映射表，可能是扩展程序并不包含源映射表",
					err,
				);
				wrapperScript.push(extensionMeta.scriptData);
			}

			wrapperScript.push(`${resolveFuncName}();`);
			wrapperScript.push("} catch (err) {");
			wrapperScript.push(`${rejectFuncName}(err);`);
			wrapperScript.push("}");
			wrapperScript.push(comment);

			const extensionFunc: () => Promise<void> = new AsyncFunction(
				"extensionContext",
				resolveFuncName,
				rejectFuncName,
				waitForDependencyFuncName,
				wrapperScript.join("\n"),
			).bind(context, context, extPromise[1], extPromise[2], waitForDependency);

			if (canceled) return;
			await extensionFunc();
			context.dispatchEvent(new Event("extension-load"));

			console.log(
				LOG_TAG,
				"扩展程序",
				extensionMeta.id,
				extensionMeta.fileName,
				"加载完成",
			);
			setLoadedExtension((v) => [...v, loadedExt]);
		})();
		return () => {
			canceled = true;
			const notify = new Notify();
			cancelRef.current = notify;
			(async () => {
				context.dispatchEvent(new Event("extension-unload"));
				setLoadedExtension((v) => v.filter((e) => e !== loadedExt));
				notify.notify();
			})();
		};
	}, [
		extensionMeta,
		i18n,
		store,
		waitForDependency,
		setLoadedExtension,
		extPromise,
	]);

	return null;
};

export const ExtensionContext: FC = () => {
	const extensionMeta = useAtomValue(extensionMetaAtom);

	const loadableExtensions = useMemo(
		() =>
			extensionMeta.filter(
				(v: ExtensionMetaState) =>
					v.loadResult === ExtensionLoadResult.Loadable,
			),
		[extensionMeta],
	);

	type PromiseTuple = readonly [
		Promise<void>,
		() => void,
		(err: Error) => void,
	];

	const loadingPromisesMap = useMemo(
		() =>
			new Map<string, PromiseTuple>(
				loadableExtensions.map((state: ExtensionMetaState) => {
					let resolve: () => void = () => {};
					let reject: (err: Error) => void = () => {};
					const p = new Promise<void>((res, rej) => {
						resolve = res;
						reject = rej;
					});
					return [state.id, [p, resolve, reject] as const] as const;
				}),
			),
		[loadableExtensions],
	);

	const waitForDependency = useCallback(
		async (extensionId: string) => {
			const promise = loadingPromisesMap.get(extensionId);
			if (promise) {
				await promise[0];
			} else {
				throw new Error(`Missing Dependency: ${extensionId}`);
			}
		},
		[loadingPromisesMap],
	);

	return loadableExtensions.map((metaState: ExtensionMetaState) => {
		const extPromise = loadingPromisesMap.get(metaState.id);

		if (!extPromise) {
			return null;
		}

		return (
			<SingleExtensionContext
				key={`${metaState.fileName}-${metaState.id}`}
				extensionMeta={metaState}
				waitForDependency={waitForDependency}
				extPromise={extPromise}
			/>
		);
	});
};

export default ExtensionContext;
