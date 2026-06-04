import { TTMLParser, toAmllLyrics } from "@applemusic-like-lyrics/ttml";
import { stringifyTTML } from "./formats/ttml";
import type { LyricLine, LyricWord, TTMLLyric } from "./types";

export { stringifyAss } from "./formats/ass";
export { decryptQrcHex, encryptQrcHex } from "./formats/eqrc";
export { parseEslrc, stringifyEslrc } from "./formats/eslrc";
export { parseLqe, stringifyLqe } from "./formats/lqe";
export { parseLrc, stringifyLrc } from "./formats/lrc";
export { parseLrcA2, stringifylrcA2 } from "./formats/lrca2";
export { parseLyl, stringifyLyl } from "./formats/lyl";
export { parseLys, stringifyLys } from "./formats/lys";
export { parseQrc, stringifyQrc } from "./formats/qrc";
export { parseYrc, stringifyYrc } from "./formats/yrc";
export type { LyricLine, LyricWord, TTMLLyric } from "./types";

const TTML_NS = "http://www.w3.org/ns/ttml";
const ROLE_ATTR_NAMES = ["role", "ttm:role"];
const PREFERRED_TRANSLATION_LANGUAGES = [
	"zh-Hans",
	"zh-Hans-CN",
	"zh-CN",
	"zh",
	"cmn-Hans",
];

function parseTimeMs(value: string | null): number {
	if (!value) return 0;
	const trimmed = value.trim();
	const parts = trimmed.split(":");
	const secondsText = parts.pop();
	if (!secondsText) return 0;
	const seconds = Number(secondsText);
	const minutes = parts.length > 0 ? Number(parts.pop()) : 0;
	const hours = parts.length > 0 ? Number(parts.pop()) : 0;
	if (![seconds, minutes, hours].every(Number.isFinite)) return 0;
	return Math.round(((hours * 60 + minutes) * 60 + seconds) * 1000);
}

function getLocalName(element: Element): string {
	return (element.localName || element.tagName || "")
		.toLowerCase()
		.split(":")
		.pop() || "";
}

function getRole(element: Element): string {
	for (const attr of ROLE_ATTR_NAMES) {
		const value = element.getAttribute(attr);
		if (value) return value.toLowerCase();
	}
	return "";
}

function getText(element: Element): string {
	return (element.textContent || "").replace(/\s+/g, " ").trim();
}

function getPElements(doc: Document): Element[] {
	const namespaced = Array.from(doc.getElementsByTagNameNS(TTML_NS, "p"));
	if (namespaced.length > 0) return namespaced;
	return Array.from(doc.getElementsByTagName("p"));
}

function getDirectSpans(element: Element): Element[] {
	return Array.from(element.childNodes).filter(
		(node): node is Element =>
			node.nodeType === 1 && getLocalName(node as Element) === "span",
	);
}

function collectTranslationLanguages(result: ReturnType<typeof TTMLParser.parse>) {
	const languages: string[] = [];
	const pushFrom = (
		items: Array<{ language?: string }> | undefined,
	) => {
		if (!items) return;
		for (const item of items) {
			if (item.language) languages.push(item.language);
		}
	};

	for (const line of result.lines) {
		pushFrom(line.translations);
		pushFrom(line.backgroundVocal?.translations);
	}

	return languages;
}

function resolvePreferredTranslationLanguage(
	result: ReturnType<typeof TTMLParser.parse>,
): string | undefined {
	const languages = collectTranslationLanguages(result);
	for (const preferred of PREFERRED_TRANSLATION_LANGUAGES) {
		const exact = languages.find((language) => language === preferred);
		if (exact) return exact;
	}
	return languages.find((language) =>
		language.toLowerCase().startsWith("zh"),
	);
}

function parseUpstreamTTMLForApp(ttmlText: string): TTMLLyric {
	const result = TTMLParser.parse(ttmlText);
	const translationLanguage = resolvePreferredTranslationLanguage(result);
	return toAmllLyrics(
		result,
		translationLanguage ? { translationLanguage } : undefined,
	);
}

function parseLegacyPlainTTML(ttmlText: string): TTMLLyric {
	if (typeof DOMParser === "undefined") {
		return { lines: [], metadata: [] };
	}

	const doc = new DOMParser().parseFromString(ttmlText, "application/xml");
	const parserError = doc.getElementsByTagName("parsererror")[0];
	if (parserError) return { lines: [], metadata: [] };

	const lines: LyricLine[] = [];

	for (const p of getPElements(doc)) {
		const startTime = parseTimeMs(p.getAttribute("begin"));
		const endTime = parseTimeMs(p.getAttribute("end"));
		const text = getText(p);
		if (!text || (startTime === 0 && endTime === 0)) continue;

		let translatedLyric = "";
		let romanLyric = "";
		const words: LyricWord[] = [];

		for (const span of getDirectSpans(p)) {
			const role = getRole(span);
			const spanText = getText(span);
			if (!spanText) continue;
			if (role.includes("translation")) {
				translatedLyric ||= spanText;
				continue;
			}
			if (role.includes("roman")) {
				romanLyric ||= spanText;
				continue;
			}
			if (role.includes("bg")) continue;

			const wordStart = parseTimeMs(span.getAttribute("begin"));
			const wordEnd = parseTimeMs(span.getAttribute("end"));
			if (wordStart > 0 || wordEnd > 0) {
				words.push({
					startTime: wordStart,
					endTime: wordEnd,
					word: spanText,
					romanWord: "",
				});
			}
		}

		lines.push({
			words:
				words.length > 0
					? words
					: [{ startTime: 0, endTime: 0, word: text, romanWord: "" }],
			translatedLyric,
			romanLyric,
			isBG: false,
			isDuet: false,
			startTime,
			endTime,
		});
	}

	return { lines, metadata: [] };
}

export function parseTTML(ttmlText: string): TTMLLyric {
	const result = parseUpstreamTTMLForApp(ttmlText);
	if (result.lines.length > 0) return result;

	const fallback = parseLegacyPlainTTML(ttmlText);
	return fallback.lines.length > 0 ? fallback : result;
}

export { stringifyTTML };
