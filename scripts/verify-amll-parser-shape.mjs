import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";

const repoRoot = path.resolve(new URL("..", import.meta.url).pathname);
const amllSourceRoot = process.env.AMLL_SOURCE
	? path.resolve(process.env.AMLL_SOURCE)
	: "/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-integration";
const appAMLLDir = process.env.APP_AMLL_DIR
	? path.resolve(process.env.APP_AMLL_DIR)
	: path.join(repoRoot, "myPlayer2", "Resources", "AMLL");
const oldBundlePath = process.env.OLD_AMLL_CORE
	? path.resolve(process.env.OLD_AMLL_CORE)
	: "/Users/kmg/Documents/vscode/player/amll-sources/_backups/current-app-amll-bundle-20260513/Resources-AMLL/amll-core.js";
const newParserPath = process.env.NEW_AMLL_LYRIC
	? path.resolve(process.env.NEW_AMLL_LYRIC)
	: path.join(appAMLLDir, "amll-lyric.js");
const samplePaths = (process.env.AMLL_PARSER_SAMPLES
	? process.env.AMLL_PARSER_SAMPLES.split(":")
	: [path.join(appAMLLDir, "sample.ttml")]
).map((item) => path.resolve(item));

globalThis.MouseEvent ??= class MouseEvent {};
globalThis.EventTarget ??= class EventTarget {};
if (typeof globalThis.DOMParser === "undefined") {
	const requireFromAMLL = createRequire(
		path.join(amllSourceRoot, "packages", "ttml", "package.json"),
	);
	const { DOMParser } = requireFromAMLL("@xmldom/xmldom");
	globalThis.DOMParser = DOMParser;
}
globalThis.ResizeObserver ??= class ResizeObserver {
	observe() {}
	unobserve() {}
	disconnect() {}
};
globalThis.document ??= {
	createElement() {
		return {
			classList: { add() {}, remove() {}, toggle() {} },
			style: { setProperty() {} },
			appendChild() {},
			remove() {},
		};
	},
};
globalThis.window ??= {
	addEventListener() {},
	removeEventListener() {},
	devicePixelRatio: 1,
};

const importFresh = async (filePath) => {
	const url = pathToFileURL(filePath);
	url.searchParams.set("t", `${Date.now()}-${Math.random()}`);
	return import(url.href);
};

const oldModule = await importFresh(oldBundlePath);
const newModule = await importFresh(newParserPath);

if (typeof oldModule.parseTTML !== "function") {
	throw new Error(`old parseTTML missing: ${oldBundlePath}`);
}
if (typeof newModule.parseTTML !== "function") {
	throw new Error(`new parseTTML missing: ${newParserPath}`);
}

const normalizeText = (value) =>
	(typeof value === "string" ? value : "").replace(/\s+/g, " ").trim();

const normalizeWord = (word) => {
	const text = normalizeText(word?.word);
	const startTime = Number.isFinite(word?.startTime)
		? Math.round(word.startTime)
		: null;
	const endTime = Number.isFinite(word?.endTime)
		? Math.round(word.endTime)
		: null;
	if (!text && (!startTime || startTime === 0) && (!endTime || endTime === 0)) {
		return null;
	}
	return {
		word: text,
		startTime,
		endTime,
		romanWord: normalizeText(word?.romanWord),
		rubyCount: Array.isArray(word?.ruby) ? word.ruby.length : 0,
	};
};

const normalizeLine = (line) => ({
	startTime: Number.isFinite(line?.startTime) ? Math.round(line.startTime) : null,
	endTime: Number.isFinite(line?.endTime) ? Math.round(line.endTime) : null,
	isBG: line?.isBG === true,
	isDuet: line?.isDuet === true,
	translatedLyric: normalizeText(line?.translatedLyric),
	romanLyric: normalizeText(line?.romanLyric),
	words: Array.isArray(line?.words)
		? line.words.map(normalizeWord).filter(Boolean)
		: [],
});

const normalizeMetadata = (metadata) => {
	if (Array.isArray(metadata)) {
		return Object.fromEntries(
			metadata
				.map(([key, value]) => [
					String(key),
					Array.isArray(value) ? value.map(String) : [],
				])
				.sort(([left], [right]) => left.localeCompare(right)),
		);
	}
	if (metadata && typeof metadata === "object") {
		return Object.fromEntries(
			Object.entries(metadata)
				.map(([key, value]) => [
					key,
					Array.isArray(value) ? value.map(String) : value,
				])
				.sort(([left], [right]) => left.localeCompare(right)),
		);
	}
	return {};
};

const normalizeResult = (result) => ({
	lines: Array.isArray(result?.lines) ? result.lines.map(normalizeLine) : [],
	metadata: normalizeMetadata(result?.metadata),
});

const collectDiffs = (oldValue, newValue, label, diffs, limit = 80) => {
	if (diffs.length >= limit) return;
	if (Object.is(oldValue, newValue)) return;
	const oldType = Array.isArray(oldValue) ? "array" : typeof oldValue;
	const newType = Array.isArray(newValue) ? "array" : typeof newValue;
	if (Array.isArray(oldValue) && Array.isArray(newValue)) {
		if (oldValue.length !== newValue.length) {
			diffs.push({
				path: `${label}.length`,
				old: oldValue.length,
				new: newValue.length,
			});
			if (diffs.length >= limit) return;
		}
		const count = Math.min(oldValue.length, newValue.length);
		for (let i = 0; i < count; i += 1) {
			collectDiffs(oldValue[i], newValue[i], `${label}[${i}]`, diffs, limit);
			if (diffs.length >= limit) return;
		}
		return;
	}
	if (oldValue && newValue && oldType === "object" && newType === "object") {
		const keys = new Set([...Object.keys(oldValue), ...Object.keys(newValue)]);
		for (const key of keys) {
			collectDiffs(oldValue[key], newValue[key], `${label}.${key}`, diffs, limit);
			if (diffs.length >= limit) return;
		}
		return;
	}
	diffs.push({ path: label, old: oldValue, new: newValue });
};

let hasDiff = false;

for (const samplePath of samplePaths) {
	const text = await readFile(samplePath, "utf8");
	let oldResult;
	let newResult;
	try {
		oldResult = normalizeResult(oldModule.parseTTML(text));
	} catch (error) {
		hasDiff = true;
		console.log(
			`[AMLL Parser Diff] ${samplePath}: OLD_PARSE_ERROR ${error?.message || error}`,
		);
		continue;
	}
	try {
		newResult = normalizeResult(newModule.parseTTML(text));
	} catch (error) {
		hasDiff = true;
		console.log(
			`[AMLL Parser Diff] ${samplePath}: NEW_PARSE_ERROR ${error?.message || error}`,
		);
		continue;
	}
	const lineDiffs = [];
	const metadataDiffs = [];
	collectDiffs(
		oldResult.lines,
		newResult.lines,
		`${path.basename(samplePath)}.lines`,
		lineDiffs,
	);
	collectDiffs(
		oldResult.metadata,
		newResult.metadata,
		`${path.basename(samplePath)}.metadata`,
		metadataDiffs,
	);
	if (lineDiffs.length > 0) {
		hasDiff = true;
		console.log(
			`[AMLL Parser Diff] ${samplePath}: FAIL oldLines=${oldResult.lines.length} newLines=${newResult.lines.length}`,
		);
		console.log(JSON.stringify(lineDiffs.slice(0, 20), null, 2));
	} else {
		console.log(
			`[AMLL Parser Diff] ${samplePath}: OK lines=${newResult.lines.length} metadataDiffs=${metadataDiffs.length}`,
		);
		if (metadataDiffs.length > 0) {
			console.log(
				`[AMLL Parser Diff] ${samplePath}: metadata differs but line shape is compatible`,
			);
			console.log(JSON.stringify(metadataDiffs.slice(0, 10), null, 2));
		}
	}
}

if (hasDiff) {
	process.exitCode = 1;
}
