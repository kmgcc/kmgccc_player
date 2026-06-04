import type { LyricWord } from "../interfaces.ts";
import { isCJK } from "./is-cjk.ts";

const SPLIT_WHITESPACE_RE = /(\s+)/;
const WHITESPACE_RE = /\s/g;

const hasWordSegmenter =
	typeof Intl !== "undefined" && typeof Intl.Segmenter !== "undefined";

function isSegmentableCJKWord(item: LyricWord | LyricWord[]): item is LyricWord {
	return (
		!Array.isArray(item) &&
		item.word.trim().length > 0 &&
		(item.ruby?.length ?? 0) === 0 &&
		isCJK(item.word)
	);
}

function groupCJKWordsBySegmenter(
	items: (LyricWord | LyricWord[])[],
): (LyricWord | LyricWord[])[] {
	if (!hasWordSegmenter) return items;

	const segmenter = new Intl.Segmenter(undefined, { granularity: "word" });
	const result: (LyricWord | LyricWord[])[] = [];

	for (let i = 0; i < items.length; i++) {
		const item = items[i];
		if (!isSegmentableCJKWord(item)) {
			result.push(item);
			continue;
		}

		const run: LyricWord[] = [item];
		while (i + 1 < items.length && isSegmentableCJKWord(items[i + 1])) {
			run.push(items[i + 1] as LyricWord);
			i++;
		}

		const fullText = run.map((word) => word.word).join("");
		const segments = Array.from(segmenter.segment(fullText));
		let wordIndex = 0;

		for (const segment of segments) {
			const segmentGroup: LyricWord[] = [];
			let remainingLength = segment.segment.length;

			while (remainingLength > 0 && wordIndex < run.length) {
				const word = run[wordIndex];
				const wordLength = word.word.length;
				segmentGroup.push(word);
				wordIndex++;
				remainingLength -= wordLength;
			}

			if (segmentGroup.length === 1) {
				result.push(segmentGroup[0]);
			} else if (segmentGroup.length > 1) {
				result.push(segmentGroup);
			}
		}

		while (wordIndex < run.length) {
			result.push(run[wordIndex++]);
		}
	}

	return result;
}

/**
 * 将输入的单词重新分组，之间没有空格的单词将会组合成一个单词数组
 *
 * 例如输入：`["Life", " ", "is", " a", " su", "gar so", "sweet"]`
 *
 * 应该返回：`["Life", " ", "is", " a", [" su", "gar"], "so", "sweet"]`
 * @param words 输入的单词数组
 * @returns 重新分组后的单词数组
 */
export function chunkAndSplitLyricWords(
	words: LyricWord[],
): (LyricWord | LyricWord[])[] {
	const result: (LyricWord | LyricWord[])[] = [];
	let currentGroup: LyricWord[] = [];

	const flushGroup = () => {
		if (currentGroup.length > 0) {
			result.push(
				currentGroup.length === 1 ? currentGroup[0] : [...currentGroup],
			);
			currentGroup = [];
		}
	};

	const processAtom = (atom: LyricWord) => {
		const isSpace = atom.word.trim().length === 0;
		const hasRuby = (atom.ruby?.length ?? 0) > 0;
		const isCJKChar = isCJK(atom.word);

		const isMergeable = !isSpace && !hasRuby && !isCJKChar;

		if (isMergeable) {
			currentGroup.push(atom);
		} else {
			flushGroup();
			result.push(atom);
		}
	};

	for (const w of words) {
		const content = w.word.trim();
		const isSpace = content.length === 0;
		const romanWord = w.romanWord ?? "";
		const obscene = w.obscene ?? false;
		const hasRuby = (w.ruby?.length ?? 0) > 0;

		if (isSpace || hasRuby) {
			processAtom({ ...w });
			continue;
		}

		const parts = w.word.split(SPLIT_WHITESPACE_RE).filter((p) => p.length > 0);

		const totalLength = w.word.replace(WHITESPACE_RE, "").length || 1;
		const timeSpan = w.endTime - w.startTime;
		const timePerUnit = timeSpan / totalLength;

		let currentOffset = 0;

		for (const part of parts) {
			if (!part.trim()) {
				const startTime = w.startTime + currentOffset * timePerUnit;
				processAtom({
					word: part,
					romanWord: "",
					startTime: startTime,
					endTime: startTime,
					obscene: obscene,
				});
				continue;
			}

			if (isCJK(part) && part.length > 1 && romanWord.trim().length === 0) {
				const chars = part.split("");
				for (const char of chars) {
					const startTime = w.startTime + currentOffset * timePerUnit;
					processAtom({
						word: char,
						romanWord: "",
						startTime: startTime,
						endTime: startTime + timePerUnit,
						obscene: obscene,
					});
					currentOffset += 1;
				}
			} else {
				const partRealLen = part.length;
				const startTime = w.startTime + currentOffset * timePerUnit;
				const duration = partRealLen * timePerUnit;

				processAtom({
					word: part,
					romanWord: romanWord,
					startTime: startTime,
					endTime: startTime + duration,
					obscene: obscene,
				});
				currentOffset += partRealLen;
			}
		}
	}

	flushGroup();

	return groupCJKWordsBySegmenter(result);
}
