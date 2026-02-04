import { atom } from "jotai";
import type { PlayerExtensionContext } from "../components/ExtensionContext/ext-ctx";

// ==================================================================
//                            类型定义
// ==================================================================

/**
 * 定义了扩展加载过程可能出现的各种结果状态。
 */
export enum ExtensionLoadResult {
	Loadable = "loadable",
	Disabled = "disabled",
	InvaildExtensionFile = "invaild-extension-file",
	ExtensionIdConflict = "extension-id-conflict",
	MissingMetadata = "missing-metadata",
	MissingDependency = "missing-dependency",
	JavaScriptFileCorrupted = "javascript-file-corrupted",
}

/**
 * 定义了扩展的元数据结构。
 * `manifest.json` 中的所有字段都会被包含进来。
 */
export interface ExtensionMetaState {
	loadResult: ExtensionLoadResult;
	id: string;
	fileName: string;
	scriptData: string;
	dependency: string[];
	[key: string]: string | string[] | undefined;
}

/**
 * 定义了一个已成功加载并实例化的扩展的结构。
 */
export interface LoadedExtension {
	extensionMeta: ExtensionMetaState;
	extensionFunc: () => Promise<void>;
	context: PlayerExtensionContext;
}

// ==================================================================
//                        扩展系统原子状态
// ==================================================================

/**
 * 一个用于触发 `extensionMetaAtom` 重新加载的原子状态。
 * 通过增加它的值来触发依赖于它的派生 Atom 重新计算。
 */
export const reloadExtensionMetaAtom = atom(0);

/**
 * 存储当前已加载并成功运行的扩展实例列表。
 */
export const loadedExtensionAtom = atom<LoadedExtension[]>([]);
