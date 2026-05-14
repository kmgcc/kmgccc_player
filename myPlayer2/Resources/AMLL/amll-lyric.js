//#region ../ttml/src/constants.ts
/**
* 一些常量定义
* @module constants
* @internal
*/
const NS = {
	TT: "http://www.w3.org/ns/ttml",
	TTM: "http://www.w3.org/ns/ttml#metadata",
	ITUNES: "http://music.apple.com/lyric-ttml-internal",
	AMLL: "http://www.example.com/ns/amll",
	XML: "http://www.w3.org/XML/1998/namespace",
	XMLNS: "http://www.w3.org/2000/xmlns/",
	ITUNES_INTERNAL: "http://music.apple.com/lyric-ttml-internal",
	TTS: "http://www.w3.org/ns/ttml#styling"
};
const Elements = {
	TT: "tt",
	Head: "head",
	Body: "body",
	Div: "div",
	P: "p",
	Span: "span",
	Title: "title",
	Name: "name",
	Meta: "meta",
	ITunesMetadata: "iTunesMetadata",
	TTMLMetadata: "metadata",
	Songwriters: "songwriters",
	Songwriter: "songwriter",
	Translation: "translation",
	Translations: "translations",
	Transliteration: "transliteration",
	Transliterations: "transliterations",
	Text: "text",
	ParserError: "parsererror",
	Agent: "agent"
};
const Attributes = {
	Timing: "timing",
	Id: "id",
	Key: "key",
	Value: "value",
	Lang: "lang",
	For: "for",
	SongPart: "songPart",
	SongPartKebab: "song-part",
	Begin: "begin",
	End: "end",
	Role: "role",
	Type: "type",
	Dur: "dur",
	Xmlns: "xmlns",
	Ruby: "ruby",
	Obscene: "obscene",
	EmptyBeat: "empty-beat"
};
const QualifiedAttributes = {
	ITunesTiming: "itunes:timing",
	ITunesPart: "itunes:songPart",
	ITunesKey: "itunes:key",
	TTMAgent: "ttm:agent",
	TTMRole: "ttm:role",
	TTMName: "ttm:name",
	AmllMeta: "amll:meta",
	AmllObscene: "amll:obscene",
	AmllEmptyBeat: "amll:empty-beat",
	XmlLang: "xml:lang",
	XmlId: "xml:id",
	XmlnsTtm: "xmlns:ttm",
	XmlnsTts: "xmlns:tts",
	XmlnsItunes: "xmlns:itunes",
	XmlnsAmll: "xmlns:amll",
	TtsRuby: "tts:ruby"
};
const Values = {
	Word: "Word",
	Line: "Line",
	MimeXML: "application/xml",
	MusicName: "musicName",
	Artists: "artists",
	Album: "album",
	ISRC: "isrc",
	TTMLAuthorGithub: "ttmlAuthorGithub",
	TTMLAuthorGithubLogin: "ttmlAuthorGithubLogin",
	NCMMusicId: "ncmMusicId",
	QQMusicId: "qqMusicId",
	SpotifyId: "spotifyId",
	AppleMusicId: "appleMusicId",
	RoleBg: "x-bg",
	RoleTranslation: "x-translation",
	RoleRoman: "x-roman",
	Group: "group",
	Person: "person",
	Other: "other",
	Full: "full",
	AgentGroup: "v1000",
	AgentDefault: "v1",
	AgentDefaultDuet: "v2",
	RubyContainer: "container",
	RubyBase: "base",
	RubyTextContainer: "textContainer",
	RubyText: "text",
	True: "true",
	TimingMode: "timingMode",
	Language: "language"
};
//#endregion
//#region ../ttml/src/generator.ts
/**
* 核心的 TTML 生成器实现
* @module generator
*/
/**
* TTML 歌词生成器类
*
* 用于将内部的 {@link TTMLResult} 数据结构序列化为 AMLL 项目使用的 TTML 字符串
* @see https://github.com/amll-dev/amll-ttml-db/wiki/%E6%A0%BC%E5%BC%8F%E8%A7%84%E8%8C%83
*/
var TTMLGenerator = class TTMLGenerator {
	domImpl;
	options;
	xmlSerializer;
	doc;
	timingMode = "Line";
	/**
	* 构造一个 TTML 生成器实例
	*
	* @param options 生成器配置选项
	*
	* 在 Node.js 环境下必须注入 `domImplementation` 和 `xmlSerializer` 实例（例如用 `@xmldom/xmldom` 等）
	*/
	constructor(options = {}) {
		this.options = options;
		if (this.options.domImplementation) this.domImpl = this.options.domImplementation;
		else if (typeof document !== "undefined" && document.implementation) this.domImpl = document.implementation;
		else throw new Error("No DOMImplementation found. If you are running in Node.js, please inject via options (e.g., using @xmldom/xmldom in Node.js).");
		if (this.options.xmlSerializer) this.xmlSerializer = this.options.xmlSerializer;
		else if (typeof XMLSerializer !== "undefined") this.xmlSerializer = new XMLSerializer();
		else throw new Error("No XMLSerializer found. If you are running in Node.js, please inject via options (e.g., using @xmldom/xmldom in Node.js).");
	}
	/**
	* 生成 TTML 字符串的静态便捷方法
	* @param result 包含元数据和歌词行的 TTML 数据结构
	* @param options 生成器配置选项，用于注入 DOM 依赖及自定义部分生成行为
	* @returns 序列化后的 TTML 字符串
	*/
	static generate(result, options) {
		return new TTMLGenerator(options).generate(result);
	}
	/**
	* 生成 TTML 字符串
	* @param result 包含元数据和歌词行的 TTML 数据结构
	* @returns 序列化后的 TTML 字符串
	*/
	generate(result) {
		this.doc = this.domImpl.createDocument(NS.TT, Elements.TT, null);
		this.timingMode = result.metadata.timingMode || "Line";
		const allLinesHaveId = result.lines.every((line) => typeof line.id === "string" && line.id.trim() !== "");
		result.lines.forEach((line, index) => {
			if (!allLinesHaveId) line.id = `L${index + 1}`;
			if (!line.agentId) line.agentId = Values.AgentDefault;
		});
		const root = this.doc.documentElement;
		this.setupRootAttributes(root, result);
		const head = this.buildHead(result);
		root.appendChild(head);
		const body = this.buildBody(result);
		root.appendChild(body);
		return this.xmlSerializer.serializeToString(this.doc);
	}
	setupRootAttributes(root, result) {
		root.setAttributeNS(NS.XMLNS, QualifiedAttributes.XmlnsAmll, NS.AMLL);
		root.setAttributeNS(NS.XMLNS, QualifiedAttributes.XmlnsItunes, NS.ITUNES);
		root.setAttributeNS(NS.XMLNS, QualifiedAttributes.XmlnsTtm, NS.TTM);
		root.setAttributeNS(NS.XMLNS, QualifiedAttributes.XmlnsTts, NS.TTS);
		if (result.metadata.language) root.setAttributeNS(NS.XML, QualifiedAttributes.XmlLang, result.metadata.language);
		if (result.metadata.timingMode) root.setAttributeNS(NS.ITUNES, QualifiedAttributes.ITunesTiming, result.metadata.timingMode);
		else root.setAttributeNS(NS.ITUNES, QualifiedAttributes.ITunesTiming, "Word");
	}
	isLyricBase(content) {
		return "startTime" in content;
	}
	isWordByWord(words) {
		if (!words || words.length === 0) return false;
		if (this.timingMode === "Word") return true;
		return true;
	}
	shouldMoveToSidecar(content) {
		if (content.words && content.words.length > 0) return true;
		return !!this.options.useSidecar;
	}
	buildHead(result) {
		const head = this.doc.createElement(Elements.Head);
		const metadata = this.doc.createElement(Elements.TTMLMetadata);
		const meta = result.metadata;
		let agentsToGenerate = [];
		if (meta.agents && Object.keys(meta.agents).length > 0) agentsToGenerate = Object.values(meta.agents);
		else {
			const uniqueAgentIds = /* @__PURE__ */ new Set();
			result.lines.forEach((line) => {
				if (line.agentId) uniqueAgentIds.add(line.agentId);
			});
			uniqueAgentIds.forEach((id) => {
				agentsToGenerate.push({
					id,
					type: id === Values.AgentGroup ? Values.Group : Values.Person
				});
			});
		}
		agentsToGenerate.forEach((agent) => {
			const { id, name, type: agentType } = agent;
			const agentEl = this.doc.createElementNS(NS.TTM, QualifiedAttributes.TTMAgent);
			const type = agentType || (id === Values.AgentGroup ? Values.Group : Values.Person);
			agentEl.setAttribute(Attributes.Type, type);
			agentEl.setAttribute(QualifiedAttributes.XmlId, id);
			if (name) {
				const nameEl = this.doc.createElementNS(NS.TTM, QualifiedAttributes.TTMName);
				nameEl.setAttribute(Attributes.Type, Values.Full);
				nameEl.textContent = name;
				agentEl.appendChild(nameEl);
			}
			metadata.appendChild(agentEl);
		});
		this.buildITunesMetadata(metadata, result);
		const addAmllMeta = (key, value) => {
			const el = this.doc.createElementNS(NS.AMLL, QualifiedAttributes.AmllMeta);
			el.setAttribute(Attributes.Key, key);
			el.setAttribute(Attributes.Value, value);
			metadata.appendChild(el);
		};
		meta.title?.forEach((v) => {
			addAmllMeta(Values.MusicName, v);
		});
		meta.artist?.forEach((v) => {
			addAmllMeta(Values.Artists, v);
		});
		meta.album?.forEach((v) => {
			addAmllMeta(Values.Album, v);
		});
		if (result.metadata.platformIds) Object.entries(result.metadata.platformIds).forEach(([key, values]) => {
			values?.forEach((v) => {
				addAmllMeta(key, v);
			});
		});
		meta.isrc?.forEach((v) => {
			addAmllMeta(Values.ISRC, v);
		});
		meta.authorIds?.forEach((v) => {
			addAmllMeta(Values.TTMLAuthorGithub, v);
		});
		meta.authorNames?.forEach((v) => {
			addAmllMeta(Values.TTMLAuthorGithubLogin, v);
		});
		if (meta.rawProperties) Object.entries(meta.rawProperties).forEach(([key, values]) => {
			values?.forEach((v) => {
				addAmllMeta(key, v);
			});
		});
		head.appendChild(metadata);
		return head;
	}
	buildITunesMetadata(metadataEl, result) {
		const iTunesMeta = this.doc.createElement(Elements.ITunesMetadata);
		iTunesMeta.setAttribute(Attributes.Xmlns, NS.ITUNES_INTERNAL);
		let hasContent = false;
		const translationsMap = /* @__PURE__ */ new Map();
		const romansMap = /* @__PURE__ */ new Map();
		for (const line of result.lines) {
			const pairedTrans = this.pairSubContents(line.translations, line.backgroundVocal?.translations);
			for (const pair of pairedTrans) if (pair.main && this.shouldMoveToSidecar(pair.main) || pair.bg && this.shouldMoveToSidecar(pair.bg)) {
				if (!translationsMap.has(pair.lang)) translationsMap.set(pair.lang, []);
				translationsMap.get(pair.lang)?.push({
					id: line.id,
					main: pair.main,
					bg: pair.bg
				});
			}
			const pairedRomans = this.pairSubContents(line.romanizations, line.backgroundVocal?.romanizations);
			for (const pair of pairedRomans) if (pair.main && this.shouldMoveToSidecar(pair.main) || pair.bg && this.shouldMoveToSidecar(pair.bg)) {
				if (!romansMap.has(pair.lang)) romansMap.set(pair.lang, []);
				romansMap.get(pair.lang)?.push({
					id: line.id,
					main: pair.main,
					bg: pair.bg
				});
			}
		}
		if (translationsMap.size > 0) {
			const container = this.doc.createElement(Elements.Translations);
			for (const [lang, items] of translationsMap) {
				const transEl = this.doc.createElement(Elements.Translation);
				if (lang) transEl.setAttribute(QualifiedAttributes.XmlLang, lang);
				items.forEach((item) => {
					const textEl = this.doc.createElement(Elements.Text);
					textEl.setAttribute(Attributes.For, item.id);
					if (item.main) this.appendContentToElement(textEl, item.main);
					if (item.bg) this.appendBackgroundVocal(textEl, item.bg);
					transEl.appendChild(textEl);
				});
				container.appendChild(transEl);
			}
			iTunesMeta.appendChild(container);
			hasContent = true;
		}
		if (romansMap.size > 0) {
			const container = this.doc.createElement(Elements.Transliterations);
			for (const [lang, items] of romansMap) {
				const transEl = this.doc.createElement(Elements.Transliteration);
				if (lang) transEl.setAttribute(QualifiedAttributes.XmlLang, lang);
				items.forEach((item) => {
					const textEl = this.doc.createElement(Elements.Text);
					textEl.setAttribute(Attributes.For, item.id);
					if (item.main) this.appendContentToElement(textEl, item.main);
					if (item.bg) this.appendBackgroundVocal(textEl, item.bg);
					transEl.appendChild(textEl);
				});
				container.appendChild(transEl);
			}
			iTunesMeta.appendChild(container);
			hasContent = true;
		}
		if (result.metadata.songwriters && result.metadata.songwriters.length > 0) {
			const container = this.doc.createElement(Elements.Songwriters);
			result.metadata.songwriters.forEach((name) => {
				const sw = this.doc.createElement(Elements.Songwriter);
				sw.textContent = name;
				container.appendChild(sw);
			});
			iTunesMeta.appendChild(container);
			hasContent = true;
		}
		if (hasContent) metadataEl.appendChild(iTunesMeta);
	}
	buildBody(result) {
		const body = this.doc.createElement(Elements.Body);
		const lines = result.lines;
		const lastTime = lines.length > 0 ? Math.max(...lines.map((l) => l.endTime)) : 0;
		body.setAttribute(Attributes.Dur, this.formatTime(lastTime));
		let currentDiv = null;
		let currentSongPart;
		let currentBlockIndex;
		let currentSectionEndTime = 0;
		const finalizeCurrentDiv = () => {
			if (currentDiv && currentSectionEndTime > 0) {
				currentDiv.setAttribute(Attributes.End, this.formatTime(currentSectionEndTime));
				if (currentSongPart) currentDiv.setAttributeNS(NS.ITUNES, QualifiedAttributes.ITunesPart, currentSongPart);
			}
		};
		for (const line of lines) {
			if (line.songPart !== currentSongPart || line.blockIndex !== currentBlockIndex || !currentDiv) {
				finalizeCurrentDiv();
				currentSongPart = line.songPart;
				currentBlockIndex = line.blockIndex;
				currentSectionEndTime = 0;
				currentDiv = this.doc.createElement(Elements.Div);
				currentDiv.setAttribute(Attributes.Begin, this.formatTime(line.startTime));
				body.appendChild(currentDiv);
			}
			if (line.endTime > currentSectionEndTime) currentSectionEndTime = line.endTime;
			const p = this.doc.createElement(Elements.P);
			p.setAttribute(Attributes.Begin, this.formatTime(line.startTime));
			p.setAttribute(Attributes.End, this.formatTime(line.endTime));
			p.setAttributeNS(NS.ITUNES, QualifiedAttributes.ITunesKey, line.id);
			if (line.agentId) p.setAttributeNS(NS.TTM, QualifiedAttributes.TTMAgent, line.agentId);
			this.appendContentToElement(p, line);
			currentDiv.appendChild(p);
		}
		finalizeCurrentDiv();
		return body;
	}
	pairSubContents(mainList, bgList) {
		const map = /* @__PURE__ */ new Map();
		const getEntry = (lang) => {
			let entry = map.get(lang);
			if (!entry) {
				entry = { lang };
				map.set(lang, entry);
			}
			return entry;
		};
		mainList?.forEach((item) => {
			getEntry(item.language).main = item;
		});
		bgList?.forEach((item) => {
			getEntry(item.language).bg = item;
		});
		return Array.from(map.values());
	}
	appendContentToElement(element, content, isBackground = false) {
		if (this.isWordByWord(content.words) && content.words) this.appendWords(element, content.words, isBackground);
		else {
			let text = content.text || "";
			if (isBackground) text = `(${text})`;
			element.textContent = text;
		}
		if (this.isLyricBase(content)) this.appendSubLyrics(element, content);
		if ("backgroundVocal" in content && content.backgroundVocal) this.appendBackgroundVocal(element, content.backgroundVocal);
	}
	appendWords(element, words, isBackground) {
		words.forEach((syllable, index) => {
			let text = syllable.text;
			if (isBackground) {
				if (index === 0) text = `(${text}`;
				if (index === words.length - 1) text = `${text})`;
			}
			if (syllable.ruby && syllable.ruby.length > 0) this.appendRubySyllable(element, syllable, text);
			else this.appendNormalSyllable(element, syllable, text);
			if (syllable.endsWithSpace) {
				const spaceNode = this.doc.createTextNode(" ");
				element.appendChild(spaceNode);
			}
		});
	}
	appendRubySyllable(element, syllable, text) {
		const containerSpan = this.doc.createElement(Elements.Span);
		containerSpan.setAttributeNS(NS.TTS, QualifiedAttributes.TtsRuby, Values.RubyContainer);
		if (syllable.obscene) containerSpan.setAttributeNS(NS.AMLL, QualifiedAttributes.AmllObscene, Values.True);
		if (syllable.emptyBeat !== void 0) containerSpan.setAttributeNS(NS.AMLL, QualifiedAttributes.AmllEmptyBeat, syllable.emptyBeat.toString());
		const baseSpan = this.doc.createElement(Elements.Span);
		baseSpan.setAttributeNS(NS.TTS, QualifiedAttributes.TtsRuby, Values.RubyBase);
		baseSpan.textContent = text;
		containerSpan.appendChild(baseSpan);
		const textContainerSpan = this.doc.createElement(Elements.Span);
		textContainerSpan.setAttributeNS(NS.TTS, QualifiedAttributes.TtsRuby, Values.RubyTextContainer);
		syllable.ruby?.forEach((rt) => {
			const rtSpan = this.doc.createElement(Elements.Span);
			rtSpan.setAttributeNS(NS.TTS, QualifiedAttributes.TtsRuby, Values.RubyText);
			rtSpan.setAttribute(Attributes.Begin, this.formatTime(rt.startTime));
			rtSpan.setAttribute(Attributes.End, this.formatTime(rt.endTime));
			rtSpan.textContent = rt.text;
			textContainerSpan.appendChild(rtSpan);
		});
		containerSpan.appendChild(textContainerSpan);
		element.appendChild(containerSpan);
	}
	appendNormalSyllable(element, syllable, text) {
		const span = this.doc.createElement(Elements.Span);
		span.setAttribute(Attributes.Begin, this.formatTime(syllable.startTime));
		span.setAttribute(Attributes.End, this.formatTime(syllable.endTime));
		if (syllable.obscene) span.setAttributeNS(NS.AMLL, QualifiedAttributes.AmllObscene, Values.True);
		if (syllable.emptyBeat !== void 0) span.setAttributeNS(NS.AMLL, QualifiedAttributes.AmllEmptyBeat, syllable.emptyBeat.toString());
		span.textContent = text;
		element.appendChild(span);
	}
	appendSubLyrics(element, content) {
		if (content.translations) content.translations.forEach((trans) => {
			if (!this.shouldMoveToSidecar(trans)) {
				const span = this.doc.createElement(Elements.Span);
				span.setAttributeNS(NS.TTM, QualifiedAttributes.TTMRole, Values.RoleTranslation);
				if (trans.language) span.setAttributeNS(NS.XML, QualifiedAttributes.XmlLang, trans.language);
				this.appendContentToElement(span, trans);
				element.appendChild(span);
			}
		});
		if (content.romanizations) content.romanizations.forEach((roman) => {
			if (!this.shouldMoveToSidecar(roman)) {
				const span = this.doc.createElement(Elements.Span);
				span.setAttributeNS(NS.TTM, QualifiedAttributes.TTMRole, Values.RoleRoman);
				if (roman.language) span.setAttributeNS(NS.XML, QualifiedAttributes.XmlLang, roman.language);
				this.appendContentToElement(span, roman);
				element.appendChild(span);
			}
		});
	}
	appendBackgroundVocal(element, bg) {
		const bgSpan = this.doc.createElement(Elements.Span);
		bgSpan.setAttributeNS(NS.TTM, QualifiedAttributes.TTMRole, Values.RoleBg);
		if (this.isLyricBase(bg)) {
			if (bg.startTime > 0 && bg.endTime > 0) {
				bgSpan.setAttribute(Attributes.Begin, this.formatTime(bg.startTime));
				bgSpan.setAttribute(Attributes.End, this.formatTime(bg.endTime));
			}
		}
		this.appendContentToElement(bgSpan, bg, true);
		element.appendChild(bgSpan);
	}
	formatTime(ms) {
		if (ms < 0) ms = 0;
		const totalSeconds = Math.floor(ms / 1e3);
		const milliseconds = ms % 1e3;
		const minutes = Math.floor(totalSeconds / 60);
		const seconds = totalSeconds % 60;
		const fff = milliseconds.toString().padStart(3, "0");
		if (minutes > 0) return `${minutes}:${seconds.toString().padStart(2, "0")}.${fff}`;
		else return `${seconds}.${fff}`;
	}
};
//#endregion
//#region ../ttml/src/parser.ts
/** biome-ignore-all lint/suspicious/noAssignInExpressions: intentional */
/**
* 核心的 TTML 生成器实现
* @module generator
*/
/**
* TTML 歌词生成器类
*
* 用于将 AMLL 项目使用的 TTML 字符串解析为结构化的 {@link TTMLResult} 数据结构
* @see https://github.com/amll-dev/amll-ttml-db/wiki/%E6%A0%BC%E5%BC%8F%E8%A7%84%E8%8C%83
*/
var TTMLParser = class TTMLParser {
	domParser;
	static TIME_REGEX = /^(?:(?:(?<hours>\d+):)?(?<minutes>\d+):)?(?<seconds>\d+(?:\.\d+)?)$/;
	static LEADING_SPACE_REGEX = /^\s/;
	static TRAILING_SPACE_REGEX = /\s$/;
	static MULTI_SPACE_REGEX = /\s+/g;
	normalizeText(text, trim = true) {
		if (!text) return "";
		const normalized = text.replace(TTMLParser.MULTI_SPACE_REGEX, " ");
		return trim ? normalized.trim() : normalized;
	}
	/**
	* 构造一个 TTML 解析器实例
	*
	* @param options 生成器配置选项
	*
	* 在 Node.js 环境下必须注入 `domParser` 实例（例如用 `@xmldom/xmldom` 等）
	*/
	constructor(options) {
		if (options?.domParser) this.domParser = options.domParser;
		else if (typeof DOMParser !== "undefined") this.domParser = new DOMParser();
		else throw new Error("No DOMParser found. If you are running in Node.js, please inject a DOMParser (e.g., @xmldom/xmldom).");
	}
	/**
	* 解析 TTML 字符串的静态便捷方法
	* @param xmlStr 需要解析的 TTML XML 字符串
	* @param options 解析器配置选项，用于注入 DOM 依赖
	* @returns 解析后的结构化 TTML 数据结构
	* @throws 当输入的 XML 字符串格式无效时抛出异常
	*/
	static parse(xmlStr, options) {
		return new TTMLParser(options).parse(xmlStr);
	}
	/**
	* 解析 TTML 字符串
	* @param xmlStr 需要解析的 TTML XML 字符串
	* @returns 解析后的结构化 TTML 数据结构
	* @throws 当输入的 XML 字符串格式无效时抛出异常
	*/
	parse(xmlStr) {
		if (!xmlStr || typeof xmlStr !== "string") throw new Error("TTMLParser: Input must be a valid XML string.");
		const doc = this.domParser.parseFromString(xmlStr, Values.MimeXML);
		const { metadata, sidecar } = this.parseHead(doc);
		const parserError = doc.getElementsByTagName(Elements.ParserError)[0];
		if (parserError) throw new Error(`TTMLParser: XML parsing error: ${parserError.textContent}`);
		const result = {
			metadata,
			lines: []
		};
		const root = doc.documentElement;
		if (root) {
			const lang = this.getAttr(root, NS.XML, Attributes.Lang);
			if (lang) result.metadata.language = lang;
			const timing = this.getAttr(root, NS.ITUNES, Attributes.Timing);
			if (timing && timing === Values.Word || timing === Values.Line) result.metadata.timingMode = timing;
		}
		this.parseBody(doc, result, sidecar);
		result.metadata.timingMode ??= this.inferTimingMode(result.lines);
		if (result.metadata.platformIds) result.metadata.platformIds = this.sortPlatformIds(result.metadata.platformIds);
		return result;
	}
	inferTimingMode(lines) {
		return lines.some((line) => (line.words?.length ?? 0) > 1 || (line.backgroundVocal?.words?.length ?? 0) > 1) ? "Word" : "Line";
	}
	sortPlatformIds(platformIds) {
		const preferredOrder = [
			"ncmMusicId",
			"qqMusicId",
			"spotifyId",
			"appleMusicId"
		];
		const orderedPlatformIds = {};
		for (const key of preferredOrder) if (platformIds[key]) orderedPlatformIds[key] = platformIds[key];
		for (const key of Object.keys(platformIds)) if (!orderedPlatformIds[key]) orderedPlatformIds[key] = platformIds[key];
		return orderedPlatformIds;
	}
	parseHead(doc) {
		const head = doc.getElementsByTagName(Elements.Head)[0];
		const resultMeta = {
			title: [],
			artist: [],
			album: [],
			isrc: [],
			authorIds: [],
			authorNames: [],
			songwriters: [],
			agents: {},
			rawProperties: {}
		};
		const sidecar = {};
		if (!head) return {
			metadata: resultMeta,
			sidecar
		};
		this.parseTTMElements(head, resultMeta);
		this.parseAMLLMeta(head, resultMeta);
		this.parseiTunesExtensions(head, resultMeta, sidecar);
		this.deduplicateMetadata(resultMeta);
		return {
			metadata: resultMeta,
			sidecar
		};
	}
	deduplicateMetadata(meta) {
		const dedupe = (arr) => arr ? Array.from(new Set(arr)) : [];
		meta.title = dedupe(meta.title);
		meta.artist = dedupe(meta.artist);
		meta.album = dedupe(meta.album);
		meta.isrc = dedupe(meta.isrc);
		meta.authorIds = dedupe(meta.authorIds);
		meta.authorNames = dedupe(meta.authorNames);
		meta.songwriters = dedupe(meta.songwriters);
		if (meta.platformIds) {
			for (const key of Object.keys(meta.platformIds)) if (meta.platformIds[key]) meta.platformIds[key] = dedupe(meta.platformIds[key]);
		}
		if (meta.rawProperties) {
			for (const key of Object.keys(meta.rawProperties)) if (meta.rawProperties[key]) meta.rawProperties[key] = dedupe(meta.rawProperties[key]);
		}
	}
	parseTTMElements(head, meta) {
		const titles = head.getElementsByTagNameNS(NS.TTM, Elements.Title);
		if (titles.length > 0 && titles[0].textContent) meta.title?.push(titles[0].textContent.trim());
		const agents = Array.from(head.getElementsByTagNameNS(NS.TTM, Elements.Agent));
		for (const agent of agents) {
			const id = this.getAttr(agent, NS.XML, Attributes.Id);
			if (!id) continue;
			const type = this.getAttr(agent, NS.TTM, Attributes.Type, Attributes.Type);
			const names = agent.getElementsByTagNameNS(NS.TTM, Elements.Name);
			const agentObj = { id };
			if (type) agentObj.type = type;
			if (names.length > 0 && names[0].textContent) {
				const rawName = names[0].textContent.trim();
				if (rawName.length > 0) agentObj.name = rawName;
			}
			meta.agents ??= {};
			meta.agents[id] = agentObj;
		}
	}
	parseAMLLMeta(head, meta) {
		const validMetas = Array.from(head.getElementsByTagNameNS(NS.AMLL, Elements.Meta)).filter((el) => {
			return this.getAttr(el, NS.AMLL, Attributes.Key) && this.getAttr(el, NS.AMLL, Attributes.Value);
		});
		for (const el of validMetas) {
			const key = this.getAttr(el, NS.AMLL, Attributes.Key);
			const value = this.getAttr(el, NS.AMLL, Attributes.Value)?.trim();
			if (!key || !value) continue;
			switch (key) {
				case Values.MusicName:
					meta.title?.push(value);
					break;
				case Values.Artists:
					meta.artist?.push(value);
					break;
				case Values.Album:
					meta.album?.push(value);
					break;
				case Values.ISRC:
					meta.isrc?.push(value);
					break;
				case Values.TTMLAuthorGithub:
					meta.authorIds?.push(value);
					break;
				case Values.TTMLAuthorGithubLogin:
					meta.authorNames?.push(value);
					break;
				case Values.NCMMusicId:
				case Values.QQMusicId:
				case Values.SpotifyId:
				case Values.AppleMusicId:
					meta.platformIds ??= {};
					(meta.platformIds[key] ??= []).push(value);
					break;
				default:
					meta.rawProperties ??= {};
					(meta.rawProperties[key] ??= []).push(value);
					break;
			}
		}
	}
	extractSubContent(base, lang, ignoreWords = false) {
		const result = {};
		const mainText = this.normalizeText(base.text);
		const hasMainWords = !ignoreWords && base.words && base.words.length > 0;
		if (mainText || hasMainWords) {
			const main = { text: mainText };
			if (lang) main.language = lang;
			if (hasMainWords) {
				if (!(base.words?.length === 1 && base.words?.[0].startTime === 0 && base.words?.[0].endTime === 0)) main.words = base.words;
			}
			result.main = main;
		}
		if ("backgroundVocal" in base && base.backgroundVocal) {
			const bgVocal = base.backgroundVocal;
			const bgText = this.normalizeText(bgVocal.text);
			const hasBgWords = !ignoreWords && bgVocal.words && bgVocal.words.length > 0;
			if (bgText || hasBgWords) {
				const bg = { text: bgText };
				if (lang) bg.language = lang;
				if (hasBgWords) {
					if (!(bgVocal.words?.length === 1 && bgVocal.words?.[0].startTime === 0 && bgVocal.words?.[0].endTime === 0)) bg.words = bgVocal.words;
				}
				result.bg = bg;
			}
		}
		return result;
	}
	parseiTunesExtensions(head, meta, sidecar) {
		const iTunesMetas = Array.from(head.getElementsByTagName(Elements.ITunesMetadata));
		if (iTunesMetas.length === 0) return;
		for (const iTunesMeta of iTunesMetas) {
			const songwritersContainer = iTunesMeta.getElementsByTagName(Elements.Songwriters)[0];
			if (songwritersContainer) {
				const writers = Array.from(songwritersContainer.getElementsByTagName(Elements.Songwriter));
				for (const writer of writers) {
					const name = writer.textContent?.trim();
					if (name) meta.songwriters?.push(name);
				}
			}
			const processEntries = (containerTagName, itemTagName, type) => {
				const container = iTunesMeta.getElementsByTagName(containerTagName)[0];
				if (!container) return;
				const items = Array.from(container.getElementsByTagName(itemTagName));
				for (const item of items) {
					const lang = this.getAttr(item, NS.XML, Attributes.Lang);
					const textNodes = Array.from(item.getElementsByTagName(Elements.Text));
					for (const textNode of textNodes) {
						const forId = textNode.getAttribute(Attributes.For);
						const parsedContent = this.parseCommonContent(textNode);
						if (forId) {
							const subContents = this.extractSubContent(parsedContent, lang, false);
							sidecar[forId] ??= {};
							if (subContents.main) (sidecar[forId][type] ??= []).push(subContents.main);
							if (subContents.bg) {
								const bgType = type === "translations" ? "bgTranslations" : "bgRomanizations";
								(sidecar[forId][bgType] ??= []).push(subContents.bg);
							}
						}
					}
				}
			};
			processEntries(Elements.Translations, Elements.Translation, "translations");
			processEntries(Elements.Transliterations, Elements.Transliteration, "romanizations");
		}
	}
	parseTime(timeStr) {
		if (!timeStr) return 0;
		const cleanStr = timeStr.trim();
		if (cleanStr.length === 0) return 0;
		if (cleanStr.endsWith("s")) {
			const seconds = Number(cleanStr.slice(0, -1));
			if (Number.isNaN(seconds)) return 0;
			return Math.round(seconds * 1e3);
		}
		const match = cleanStr.match(TTMLParser.TIME_REGEX);
		if (match?.groups) {
			const { seconds, minutes, hours } = match.groups;
			const secNum = Number(seconds);
			const minNum = minutes ? parseInt(minutes, 10) : 0;
			const hrNum = hours ? parseInt(hours, 10) : 0;
			if (!Number.isNaN(secNum) && !Number.isNaN(minNum) && !Number.isNaN(hrNum)) {
				const totalSeconds = hrNum * 3600 + minNum * 60 + secNum;
				return Math.round(totalSeconds * 1e3);
			}
		}
		return 0;
	}
	parseBody(doc, result, sidecar) {
		const body = doc.getElementsByTagName(Elements.Body)[0];
		if (!body) return;
		const childNodes = Array.from(body.childNodes);
		let currentBlockIndex = 0;
		for (const node of childNodes) {
			if (node.nodeType !== 1) continue;
			const el = node;
			const tagName = el.localName || el.tagName.toLowerCase().split(":").pop();
			if (tagName === Elements.Div) {
				currentBlockIndex++;
				const songPart = this.getAttr(el, NS.ITUNES, Attributes.SongPartKebab) || this.getAttr(el, NS.ITUNES, Attributes.SongPart);
				const pNodes = el.getElementsByTagNameNS(NS.TT, Elements.P);
				const pList = pNodes.length > 0 ? Array.from(pNodes) : Array.from(el.getElementsByTagName(Elements.P));
				for (const p of pList) this.processLineElement(p, result.lines, sidecar, songPart, currentBlockIndex);
			} else if (tagName === Elements.P) {
				currentBlockIndex++;
				this.processLineElement(el, result.lines, sidecar, void 0, currentBlockIndex);
			}
		}
	}
	processLineElement(p, lines, sidecar, songPart, blockIndex) {
		const id = this.getAttr(p, NS.ITUNES, Attributes.Key);
		if (!id) return;
		const line = {
			id,
			...this.parseCommonContent(p)
		};
		if (songPart) line.songPart = songPart;
		if (blockIndex !== void 0) line.blockIndex = blockIndex;
		const agentId = this.getAttr(p, NS.TTM, Elements.Agent);
		if (agentId) line.agentId = agentId;
		const externalData = sidecar[id];
		if (externalData) {
			if (externalData.translations) (line.translations ??= []).push(...externalData.translations);
			if (externalData.romanizations) (line.romanizations ??= []).push(...externalData.romanizations);
			if (externalData.bgTranslations && line.backgroundVocal) (line.backgroundVocal.translations ??= []).push(...externalData.bgTranslations);
			if (externalData.bgRomanizations && line.backgroundVocal) (line.backgroundVocal.romanizations ??= []).push(...externalData.bgRomanizations);
		}
		lines.push(line);
	}
	parseCommonContent(element) {
		const beginAttr = this.getAttr(element, NS.XML, Attributes.Begin, Attributes.Begin);
		const endAttr = this.getAttr(element, NS.XML, Attributes.End, Attributes.End);
		const originalStartTime = this.parseTime(beginAttr);
		const originalEndTime = this.parseTime(endAttr);
		const state = this.extractNodeState(element);
		if (state.backgroundVocal) {
			if (state.bgTranslations.length > 0) (state.backgroundVocal.translations ??= []).push(...state.bgTranslations);
			if (state.bgRomanizations.length > 0) (state.backgroundVocal.romanizations ??= []).push(...state.bgRomanizations);
		}
		this.finalizeWords(state.words);
		const { startTime, endTime } = this.calculateTimeRange(originalStartTime, originalEndTime, state.words, state.backgroundVocal);
		const cleanFullText = this.normalizeText(state.fullText);
		const hasTimeAttrs = beginAttr !== null || endAttr !== null;
		this.applyFallbackWord(state.words, cleanFullText, hasTimeAttrs, originalStartTime, originalEndTime, startTime, endTime);
		return this.buildLyricBase(state, cleanFullText, startTime, endTime);
	}
	extractNodeState(element) {
		const state = {
			fullText: "",
			words: [],
			translations: [],
			romanizations: [],
			bgTranslations: [],
			bgRomanizations: [],
			backgroundVocal: void 0
		};
		const childNodes = Array.from(element.childNodes);
		for (const node of childNodes) if (node.nodeType === 3) this.processTextNode(state, node);
		else if (node.nodeType === 1) this.processElementNode(state, node);
		return state;
	}
	calculateTimeRange(originalStart, originalEnd, words, bgVocal) {
		let startTime = originalStart;
		let endTime = originalEnd;
		const timedElements = [...words];
		if (bgVocal) timedElements.push(bgVocal);
		if (timedElements.length > 0) {
			let minChildStart = Infinity;
			let maxChildEnd = 0;
			for (const el of timedElements) {
				if (el.startTime < minChildStart) minChildStart = el.startTime;
				if (el.endTime > maxChildEnd) maxChildEnd = el.endTime;
			}
			if (startTime === 0 || minChildStart > 0 && minChildStart < startTime) startTime = minChildStart === Infinity ? 0 : minChildStart;
			if (endTime === 0 || maxChildEnd > endTime) endTime = maxChildEnd;
		}
		return {
			startTime,
			endTime
		};
	}
	applyFallbackWord(words, cleanText, hasTimeAttrs, origStart, origEnd, calcStart, calcEnd) {
		if (words.length === 0 && cleanText.length > 0 && hasTimeAttrs) words.push({
			text: cleanText,
			startTime: origStart > 0 ? origStart : calcStart,
			endTime: origEnd > 0 ? origEnd : calcEnd,
			endsWithSpace: false
		});
	}
	buildLyricBase(state, cleanText, startTime, endTime) {
		return {
			text: cleanText,
			startTime,
			endTime,
			words: state.words.length > 0 ? state.words : void 0,
			translations: state.translations.length > 0 ? state.translations : void 0,
			romanizations: state.romanizations.length > 0 ? state.romanizations : void 0,
			backgroundVocal: state.backgroundVocal
		};
	}
	processTextNode(state, node) {
		const rawText = node.textContent || "";
		const isFormatting = rawText.includes("\n");
		if (isFormatting && rawText.trim().length === 0) return;
		const normalizedText = this.normalizeText(rawText, false);
		state.fullText += normalizedText;
		if (!isFormatting && normalizedText.length > 0 && normalizedText.trim().length === 0) {
			if (state.words.length > 0) state.words[state.words.length - 1].endsWithSpace = true;
		}
	}
	processElementNode(state, el) {
		const role = this.getAttr(el, NS.TTM, Attributes.Role);
		if (this.getAttr(el, NS.TTS, Attributes.Ruby, QualifiedAttributes.TtsRuby) === Values.RubyContainer) {
			this.processRubyElement(state, el);
			return;
		}
		switch (role) {
			case Values.RoleBg:
				state.backgroundVocal = this.parseBackgroundVocal(el);
				break;
			case Values.RoleTranslation: {
				const translation = this.parseInlineSubContent(el);
				if (translation) {
					if (translation.main) state.translations.push(translation.main);
					if (translation.bg) state.bgTranslations.push(translation.bg);
				}
				break;
			}
			case Values.RoleRoman: {
				const romanization = this.parseInlineSubContent(el);
				if (romanization) {
					if (romanization.main) state.romanizations.push(romanization.main);
					if (romanization.bg) state.bgRomanizations.push(romanization.bg);
				}
				break;
			}
			default:
				this.processWordElement(state, el);
				break;
		}
	}
	processRubyElement(state, containerEl) {
		const isObscene = this.getAttr(containerEl, NS.AMLL, Attributes.Obscene, QualifiedAttributes.AmllObscene) === "true";
		const emptyBeatAttr = this.getAttr(containerEl, NS.AMLL, Attributes.EmptyBeat, QualifiedAttributes.AmllEmptyBeat);
		let emptyBeat;
		if (emptyBeatAttr) {
			const parsedBeat = parseInt(emptyBeatAttr, 10);
			if (!Number.isNaN(parsedBeat)) emptyBeat = parsedBeat;
		}
		let baseText = "";
		const rubyTags = [];
		const childNodes = Array.from(containerEl.childNodes);
		for (const node of childNodes) {
			if (node.nodeType !== 1) continue;
			const childEl = node;
			const childRubyAttr = this.getAttr(childEl, NS.TTS, Attributes.Ruby, QualifiedAttributes.TtsRuby);
			if (childRubyAttr === Values.RubyBase) baseText = this.normalizeText(childEl.textContent, false);
			else if (childRubyAttr === Values.RubyTextContainer) {
				const textNodes = Array.from(childEl.childNodes);
				for (const textNode of textNodes) {
					if (textNode.nodeType !== 1) continue;
					const tNode = textNode;
					if (this.getAttr(tNode, NS.TTS, Attributes.Ruby, QualifiedAttributes.TtsRuby) === Values.RubyText) {
						const begin = this.getAttr(tNode, NS.XML, Attributes.Begin, Attributes.Begin);
						const end = this.getAttr(tNode, NS.XML, Attributes.End, Attributes.End);
						const text = this.normalizeText(tNode.textContent, false).trim();
						if (text && begin && end) rubyTags.push({
							text,
							startTime: this.parseTime(begin),
							endTime: this.parseTime(end)
						});
					}
				}
			}
		}
		if (!baseText) return;
		state.fullText += baseText;
		let startTime = 0;
		let endTime = 0;
		if (rubyTags.length > 0) {
			startTime = Math.min(...rubyTags.map((t) => t.startTime));
			endTime = Math.max(...rubyTags.map((t) => t.endTime));
		}
		const cleanBaseText = baseText.trim();
		if (cleanBaseText.length > 0) {
			const endsWithSpace = TTMLParser.TRAILING_SPACE_REGEX.test(baseText);
			if (TTMLParser.LEADING_SPACE_REGEX.test(baseText) && state.words.length > 0) state.words[state.words.length - 1].endsWithSpace = true;
			state.words.push({
				text: cleanBaseText,
				startTime,
				endTime,
				ruby: rubyTags.length > 0 ? rubyTags : void 0,
				endsWithSpace,
				obscene: isObscene ? true : void 0,
				emptyBeat
			});
		}
	}
	processWordElement(state, el) {
		const wBegin = this.getAttr(el, NS.XML, Attributes.Begin, Attributes.Begin);
		const wEnd = this.getAttr(el, NS.XML, Attributes.End, Attributes.End);
		const isObscene = this.getAttr(el, NS.AMLL, Attributes.Obscene, QualifiedAttributes.AmllObscene) === "true";
		const emptyBeatAttr = this.getAttr(el, NS.AMLL, Attributes.EmptyBeat, QualifiedAttributes.AmllEmptyBeat);
		let emptyBeat;
		if (emptyBeatAttr) {
			const parsedBeat = parseInt(emptyBeatAttr, 10);
			if (!Number.isNaN(parsedBeat)) emptyBeat = parsedBeat;
		}
		const rawWText = el.textContent || "";
		const normalizedWText = this.normalizeText(rawWText, false);
		state.fullText += normalizedWText;
		if (wBegin && wEnd) {
			const isFormatting = rawWText.includes("\n");
			let startsWithSpace = false;
			let endsWithSpace = false;
			if (!isFormatting) {
				startsWithSpace = TTMLParser.LEADING_SPACE_REGEX.test(normalizedWText);
				endsWithSpace = TTMLParser.TRAILING_SPACE_REGEX.test(normalizedWText);
			}
			const cleanText = normalizedWText.trim();
			if (startsWithSpace && state.words.length > 0) state.words[state.words.length - 1].endsWithSpace = true;
			if (cleanText.length > 0) state.words.push({
				text: cleanText,
				startTime: this.parseTime(wBegin),
				endTime: this.parseTime(wEnd),
				endsWithSpace,
				obscene: isObscene ? true : void 0,
				emptyBeat
			});
		}
	}
	parseBackgroundVocal(el) {
		const { backgroundVocal, ...bgVocal } = this.parseCommonContent(el);
		bgVocal.text = bgVocal.text.replace(/^[(（]+/, "").replace(/[)）]+$/, "");
		if (bgVocal.words && bgVocal.words.length > 0) {
			bgVocal.words[0].text = bgVocal.words[0].text.replace(/^[(（]+/, "").trimStart();
			const lastIdx = bgVocal.words.length - 1;
			bgVocal.words[lastIdx].text = bgVocal.words[lastIdx].text.replace(/[)）]+$/, "").trimEnd();
		}
		return bgVocal;
	}
	parseInlineSubContent(el) {
		const lang = this.getAttr(el, NS.XML, Attributes.Lang);
		const parsed = this.parseCommonContent(el);
		const content = this.extractSubContent(parsed, lang, true);
		if (content.main || content.bg) return content;
		return null;
	}
	finalizeWords(words) {
		if (words.length === 0) return [];
		words[0].text = words[0].text.trimStart();
		const lastIdx = words.length - 1;
		words[lastIdx].text = words[lastIdx].text.trimEnd();
		words[lastIdx].endsWithSpace = false;
		return words;
	}
	getAttr(element, ns, localName, fallbackAttrName) {
		const val = element.getAttributeNS(ns, localName);
		if (val) return val;
		if (fallbackAttrName) {
			const fallbackVal = element.getAttribute(fallbackAttrName);
			if (fallbackVal) return fallbackVal;
		}
		if (element.hasAttributes()) {
			const attributes = Array.from(element.attributes);
			for (const attr of attributes) if ((attr.localName || attr.nodeName.split(":").pop()) === localName) return attr.value;
		}
		return null;
	}
};
//#endregion
//#region ../ttml/src/utils/amll-converter.ts
/**
* 包含解析器内部的复杂数据结构和 AMLL 简单的数据结构的互转功能的模块
* @module amll-converter
*/
/**
* 将本解析器复杂的数据结构降级为 AMLL 所使用的较简单的数据结构
*/
function toAmllLyrics(result, options) {
	const amllLines = [];
	const convertToAmllLine = (source, isBG, isDuet) => {
		let amllWords = [];
		if (source.words && source.words.length > 0) amllWords = source.words.map((w) => {
			const amllWord = {
				startTime: w.startTime,
				endTime: w.endTime,
				word: w.text + (w.endsWithSpace ? " " : ""),
				romanWord: "",
				obscene: w.obscene,
				emptyBeat: w.emptyBeat
			};
			if (w.ruby && w.ruby.length > 0) amllWord.ruby = w.ruby.map((r) => ({
				startTime: r.startTime,
				endTime: r.endTime,
				word: r.text
			}));
			return amllWord;
		});
		else amllWords = [{
			startTime: source.startTime,
			endTime: source.endTime,
			word: source.text,
			romanWord: ""
		}];
		let transText = "";
		if (source.translations && source.translations.length > 0) transText = (options?.translationLanguage && source.translations.find((t) => t.language === options.translationLanguage) || source.translations[0]).text;
		let romanText = "";
		let romanWords;
		if (source.romanizations && source.romanizations.length > 0) {
			const targetRoman = options?.romanizationLanguage && source.romanizations.find((r) => r.language === options.romanizationLanguage) || source.romanizations[0];
			romanWords = targetRoman.words;
			if (!romanWords || romanWords.length === 0) romanText = targetRoman.text;
		}
		if (romanWords && amllWords.length > 0) alignRomanization(amllWords, romanWords);
		return {
			words: amllWords,
			translatedLyric: transText,
			romanLyric: romanText,
			isBG,
			isDuet,
			startTime: source.startTime,
			endTime: source.endTime
		};
	};
	let lastPersonAgentId = null;
	let lastPersonIsDuet = false;
	for (const line of result.lines) {
		const agentId = line.agentId || Values.AgentDefault;
		const agent = result.metadata.agents?.[agentId];
		const isGroup = agent?.type === Values.Group;
		const isOther = agent?.type === Values.Other;
		let currentIsDuet = false;
		if (isGroup) currentIsDuet = false;
		else if (lastPersonAgentId === null) {
			currentIsDuet = !!isOther;
			lastPersonAgentId = agentId;
			lastPersonIsDuet = currentIsDuet;
		} else if (lastPersonAgentId === agentId) currentIsDuet = lastPersonIsDuet;
		else {
			currentIsDuet = !lastPersonIsDuet;
			lastPersonAgentId = agentId;
			lastPersonIsDuet = currentIsDuet;
		}
		const amllMain = convertToAmllLine(line, false, currentIsDuet);
		amllLines.push(amllMain);
		if (line.backgroundVocal) {
			const simpleBg = convertToAmllLine(line.backgroundVocal, true, currentIsDuet);
			amllLines.push(simpleBg);
		}
	}
	const amllMetadata = [];
	const meta = result.metadata;
	if (meta.title) amllMetadata.push([Values.MusicName, meta.title]);
	if (meta.artist) amllMetadata.push([Values.Artists, meta.artist]);
	if (meta.album) amllMetadata.push([Values.Album, meta.album]);
	if (meta.isrc) amllMetadata.push([Values.ISRC, meta.isrc]);
	if (meta.authorIds) amllMetadata.push([Values.TTMLAuthorGithub, meta.authorIds]);
	if (meta.authorNames) amllMetadata.push([Values.TTMLAuthorGithubLogin, meta.authorNames]);
	if (meta.language) amllMetadata.push([Values.Language, [meta.language]]);
	if (meta.timingMode) amllMetadata.push([Values.TimingMode, [meta.timingMode]]);
	if (meta.songwriters) amllMetadata.push([Elements.Songwriters, meta.songwriters]);
	if (meta.platformIds) {
		if (meta.platformIds.ncmMusicId) amllMetadata.push([Values.NCMMusicId, meta.platformIds.ncmMusicId]);
		if (meta.platformIds.qqMusicId) amllMetadata.push([Values.QQMusicId, meta.platformIds.qqMusicId]);
		if (meta.platformIds.spotifyId) amllMetadata.push([Values.SpotifyId, meta.platformIds.spotifyId]);
		if (meta.platformIds.appleMusicId) amllMetadata.push([Values.AppleMusicId, meta.platformIds.appleMusicId]);
	}
	if (meta.rawProperties) for (const [key, value] of Object.entries(meta.rawProperties)) amllMetadata.push([key, value]);
	return {
		lines: amllLines,
		metadata: amllMetadata
	};
}
function alignRomanization(amllWords, romanWords) {
	let i = 0;
	let j = 0;
	const TIME_TOLERANCE_MS = 30;
	while (i < amllWords.length && j < romanWords.length) {
		const main = amllWords[i];
		const sub = romanWords[j];
		if (Math.abs(main.startTime - sub.startTime) < TIME_TOLERANCE_MS) {
			main.romanWord = sub.text;
			i++;
			j++;
		} else if (sub.startTime < main.startTime) j++;
		else i++;
	}
}
/**
* 将 AMLL 格式的歌词和元数据转换为 TTMLResult 结构
*/
function toTTMLResult(amllLines, amllMetadata, options = {}) {
	const opts = {
		translationLanguage: "zh-Hans",
		...options
	};
	const metadata = { agents: {
		[Values.AgentDefault]: { id: Values.AgentDefault },
		[Values.AgentDefaultDuet]: { id: Values.AgentDefaultDuet }
	} };
	for (const entry of amllMetadata) {
		const [key, value] = entry;
		if (!value || value.length === 0) continue;
		switch (key) {
			case Values.MusicName:
				metadata.title = value;
				break;
			case Values.Artists:
				metadata.artist = value;
				break;
			case Values.Album:
				metadata.album = value;
				break;
			case Values.ISRC:
				metadata.isrc = value;
				break;
			case Values.TTMLAuthorGithub:
				metadata.authorIds = value;
				break;
			case Values.TTMLAuthorGithubLogin:
				metadata.authorNames = value;
				break;
			case Values.NCMMusicId:
			case Values.QQMusicId:
			case Values.SpotifyId:
			case Values.AppleMusicId:
				if (!metadata.platformIds) metadata.platformIds = {};
				metadata.platformIds[key] = value;
				break;
			default:
				if (!metadata.rawProperties) metadata.rawProperties = {};
				metadata.rawProperties[key] = value;
				break;
		}
	}
	const resultLines = [];
	let currentMainLine = null;
	for (const amllLine of amllLines) {
		const { mainSyllables, romanSyllables, fullText, romanText } = convertWords(amllLine);
		const lyricBase = {
			startTime: amllLine.startTime,
			endTime: amllLine.endTime,
			text: fullText,
			words: mainSyllables
		};
		if (amllLine.translatedLyric) lyricBase.translations = [{
			language: opts.translationLanguage,
			text: amllLine.translatedLyric
		}];
		if (amllLine.romanLyric || romanSyllables.length > 0) lyricBase.romanizations = [{
			language: opts.romanizationLanguage,
			text: amllLine.romanLyric || romanText,
			words: romanSyllables.length > 0 ? romanSyllables : void 0
		}];
		if (amllLine.isBG) if (currentMainLine && !currentMainLine.backgroundVocal) currentMainLine.backgroundVocal = lyricBase;
		else {
			const promotedLine = {
				agentId: currentMainLine ? currentMainLine.agentId : Values.AgentDefault,
				...lyricBase
			};
			resultLines.push(promotedLine);
		}
		else {
			const lyricLine = {
				agentId: amllLine.isDuet ? Values.AgentDefaultDuet : Values.AgentDefault,
				...lyricBase
			};
			resultLines.push(lyricLine);
			currentMainLine = lyricLine;
		}
	}
	return {
		metadata,
		lines: resultLines
	};
}
function convertWords(amllLine) {
	const mainSyllables = [];
	const romanSyllables = [];
	for (const word of amllLine.words) {
		const rawText = word.word;
		const trimmedText = rawText.trimEnd();
		const hasSpace = rawText !== trimmedText;
		const syllable = {
			text: trimmedText,
			startTime: word.startTime,
			endTime: word.endTime,
			endsWithSpace: hasSpace,
			obscene: word.obscene,
			emptyBeat: word.emptyBeat
		};
		if (word.ruby && word.ruby.length > 0) syllable.ruby = word.ruby.map((r) => ({
			startTime: r.startTime,
			endTime: r.endTime,
			text: r.word
		}));
		mainSyllables.push(syllable);
		if (word.romanWord) romanSyllables.push({
			text: word.romanWord.trim(),
			startTime: word.startTime,
			endTime: word.endTime
		});
	}
	return {
		mainSyllables,
		romanSyllables,
		fullText: amllLine.words.map((w) => w.word).join(""),
		romanText: romanSyllables.length > 0 ? romanSyllables.map((s) => s.text + (s.endsWithSpace ? " " : "")).join("") : ""
	};
}
//#endregion
//#region ../ttml/src/index.ts
/**
* 将 {@link AmllLyricResult} 对象序列化为 TTML 格式的 XML 字符串的便捷方法
*
* 若需要自定义生成选项，建议直接使用 {@link TTMLParser} 类
* @remarks 默认使用全局的 `document.implementation` 和 `XMLSerializer`，若为 Nodejs 环境，
* 必须使用 {@link TTMLGenerator} 类注入 `domImplementation` 和 `xmlSerializer`，例如 `@xmldom/xmldom`
* @param ttmlLyric 包含歌词行列表和元数据的 {@link AmllLyricResult} 对象
* @returns 序列化后的 TTML XML 字符串
* @throws 如果没有全局的 `DOMImplementation` 和 `XMLSerializer`，抛出错误
*/
function exportTTML(ttmlLyric) {
	const result = toTTMLResult(ttmlLyric.lines, ttmlLyric.metadata);
	return new TTMLGenerator().generate(result);
}
//#endregion
//#region src/formats/ttml.ts
/**
* 将歌词数组转换为 TTML 格式（包含 AMLL 特有属性信息）的歌词字符串
* @param ttmlLyric TTML 歌词对象
*/
function stringifyTTML(ttmlLyric) {
	return exportTTML(ttmlLyric);
}
//#endregion
//#region src/utils.ts
const createLine = (line) => ({
	words: [],
	translatedLyric: "",
	romanLyric: "",
	isBG: false,
	isDuet: false,
	startTime: 0,
	endTime: 0,
	...line
});
const createWord = (word) => ({
	startTime: 0,
	endTime: 0,
	word: "",
	...word
});
const parseTime = (time) => Math.round(time.split(":").map(Number).reverse().reduce((acc, cur, idx) => acc + cur * 60 ** idx, 0) * 1e3);
const formatTime = (ms) => {
	return `${Math.floor(ms / 6e4).toString().padStart(2, "0")}:${Math.floor(ms % 6e4 / 1e3).toString().padStart(2, "0")}.${Math.round(ms % 1e3).toString().padStart(3, "0")}`;
};
const normalizeTimestamp = (ms) => {
	if (!Number.isFinite(ms) || ms < 0) return 0;
	return ms;
};
const normalizeDuration = (duration) => {
	if (!Number.isFinite(duration) || duration < 0) return 0;
	return duration;
};
const MAX_LRC_TIMESTAMP = 60039999;
const clampTimestamp = (ms, max = MAX_LRC_TIMESTAMP) => Math.min(max, normalizeTimestamp(ms));
/**
* Returns consecutive pairs from the given iterable.
*
* Example: `0, 1, 2, 3` -> `[0, 1], [1, 2], [2, 3]`
*/
function* pairwise(iterable) {
	let prev;
	let hasPrev = false;
	for (const curr of iterable) {
		if (hasPrev) yield [prev, curr];
		prev = curr;
		hasPrev = true;
	}
}
//#endregion
//#region src/formats/ass.ts
function writeASSTimestamp(ms) {
	const normalized = normalizeTimestamp(ms);
	const milli = Math.round(normalized) % 1e3;
	const secTotal = Math.floor(Math.round(normalized) / 1e3);
	const sec = secTotal % 60;
	const minTotal = Math.floor(secTotal / 60);
	return `${Math.floor(minTotal / 60)}:${String(minTotal % 60).padStart(2, "0")}:${String(sec).padStart(2, "0")}.${String(Math.floor(milli / 10)).padStart(2, "0")}`;
}
function getSpeakerName(line) {
	let name = line.isDuet ? "v2" : "v1";
	if (line.isBG) name += "-bg";
	return name;
}
function writeLyricDialogue(result, startTime, endTime, name, text) {
	result.push(`Dialogue: 0,${writeASSTimestamp(startTime)}, ${writeASSTimestamp(endTime)}, Default, ${name},0,0,0,,${text}`);
}
/**
* 将歌词数组转换为 ASS 字幕格式字符串
* @param lines 歌词数组
* @returns ASS 字幕格式字符串
*/
function stringifyAss(lines) {
	const result = [
		"[Script Info]",
		"[Events]",
		"Formats: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
	];
	for (const line of lines) {
		const timedWords = line.words.map((w) => ({
			...w,
			startTime: normalizeTimestamp(w.startTime),
			endTime: normalizeTimestamp(w.endTime)
		})).filter((w) => w.endTime > w.startTime);
		const startTime = Math.min(...timedWords.map((w) => w.startTime));
		const endTime = Math.max(...timedWords.map((w) => w.endTime));
		if (!Number.isFinite(startTime) || !Number.isFinite(endTime)) continue;
		let lyricText = "";
		let previousWordEndTime = startTime;
		for (const word of line.words) {
			const wordStart = normalizeTimestamp(word.startTime);
			const wordEnd = normalizeTimestamp(word.endTime);
			if (wordStart >= wordEnd) {
				lyricText += word.word;
				continue;
			}
			if (wordStart > previousWordEndTime) {
				const gapDurationCS = Math.floor((wordStart - previousWordEndTime + 5) / 10);
				if (gapDurationCS > 0) lyricText += `{\\k${gapDurationCS}}`;
			}
			const wordDurationCS = Math.floor((wordEnd - wordStart + 5) / 10);
			if (wordDurationCS > 0) lyricText += `{\\k${wordDurationCS}}`;
			lyricText += word.word;
			previousWordEndTime = wordEnd;
		}
		const speaker = getSpeakerName(line);
		writeLyricDialogue(result, startTime, endTime, speaker, lyricText);
		if (line.translatedLyric) writeLyricDialogue(result, startTime, endTime, `${speaker}-trans`, line.translatedLyric);
		if (line.romanLyric) writeLyricDialogue(result, startTime, endTime, `${speaker}-roman`, line.romanLyric);
	}
	return `${result.join("\n")}\n`;
}
//#endregion
//#region ../../node_modules/.pnpm/pako@2.1.0/node_modules/pako/dist/pako.esm.mjs
/*! pako 2.1.0 https://github.com/nodeca/pako @license (MIT AND Zlib) */
const Z_FIXED$1 = 4;
const Z_BINARY = 0;
const Z_TEXT = 1;
const Z_UNKNOWN$1 = 2;
function zero$1(buf) {
	let len = buf.length;
	while (--len >= 0) buf[len] = 0;
}
const STORED_BLOCK = 0;
const STATIC_TREES = 1;
const DYN_TREES = 2;
const MIN_MATCH$1 = 3;
const MAX_MATCH$1 = 258;
const LENGTH_CODES$1 = 29;
const LITERALS$1 = 256;
const L_CODES$1 = LITERALS$1 + 1 + LENGTH_CODES$1;
const D_CODES$1 = 30;
const BL_CODES$1 = 19;
const HEAP_SIZE$1 = 2 * L_CODES$1 + 1;
const MAX_BITS$1 = 15;
const Buf_size = 16;
const MAX_BL_BITS = 7;
const END_BLOCK = 256;
const REP_3_6 = 16;
const REPZ_3_10 = 17;
const REPZ_11_138 = 18;
const extra_lbits = new Uint8Array([
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	0
]);
const extra_dbits = new Uint8Array([
	0,
	0,
	0,
	0,
	1,
	1,
	2,
	2,
	3,
	3,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	7,
	8,
	8,
	9,
	9,
	10,
	10,
	11,
	11,
	12,
	12,
	13,
	13
]);
const extra_blbits = new Uint8Array([
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	2,
	3,
	7
]);
const bl_order = new Uint8Array([
	16,
	17,
	18,
	0,
	8,
	7,
	9,
	6,
	10,
	5,
	11,
	4,
	12,
	3,
	13,
	2,
	14,
	1,
	15
]);
const DIST_CODE_LEN = 512;
const static_ltree = new Array((L_CODES$1 + 2) * 2);
zero$1(static_ltree);
const static_dtree = new Array(D_CODES$1 * 2);
zero$1(static_dtree);
const _dist_code = new Array(DIST_CODE_LEN);
zero$1(_dist_code);
const _length_code = new Array(MAX_MATCH$1 - MIN_MATCH$1 + 1);
zero$1(_length_code);
const base_length = new Array(LENGTH_CODES$1);
zero$1(base_length);
const base_dist = new Array(D_CODES$1);
zero$1(base_dist);
function StaticTreeDesc(static_tree, extra_bits, extra_base, elems, max_length) {
	this.static_tree = static_tree;
	this.extra_bits = extra_bits;
	this.extra_base = extra_base;
	this.elems = elems;
	this.max_length = max_length;
	this.has_stree = static_tree && static_tree.length;
}
let static_l_desc;
let static_d_desc;
let static_bl_desc;
function TreeDesc(dyn_tree, stat_desc) {
	this.dyn_tree = dyn_tree;
	this.max_code = 0;
	this.stat_desc = stat_desc;
}
const d_code = (dist) => {
	return dist < 256 ? _dist_code[dist] : _dist_code[256 + (dist >>> 7)];
};
const put_short = (s, w) => {
	s.pending_buf[s.pending++] = w & 255;
	s.pending_buf[s.pending++] = w >>> 8 & 255;
};
const send_bits = (s, value, length) => {
	if (s.bi_valid > Buf_size - length) {
		s.bi_buf |= value << s.bi_valid & 65535;
		put_short(s, s.bi_buf);
		s.bi_buf = value >> Buf_size - s.bi_valid;
		s.bi_valid += length - Buf_size;
	} else {
		s.bi_buf |= value << s.bi_valid & 65535;
		s.bi_valid += length;
	}
};
const send_code = (s, c, tree) => {
	send_bits(s, tree[c * 2], tree[c * 2 + 1]);
};
const bi_reverse = (code, len) => {
	let res = 0;
	do {
		res |= code & 1;
		code >>>= 1;
		res <<= 1;
	} while (--len > 0);
	return res >>> 1;
};
const bi_flush = (s) => {
	if (s.bi_valid === 16) {
		put_short(s, s.bi_buf);
		s.bi_buf = 0;
		s.bi_valid = 0;
	} else if (s.bi_valid >= 8) {
		s.pending_buf[s.pending++] = s.bi_buf & 255;
		s.bi_buf >>= 8;
		s.bi_valid -= 8;
	}
};
const gen_bitlen = (s, desc) => {
	const tree = desc.dyn_tree;
	const max_code = desc.max_code;
	const stree = desc.stat_desc.static_tree;
	const has_stree = desc.stat_desc.has_stree;
	const extra = desc.stat_desc.extra_bits;
	const base = desc.stat_desc.extra_base;
	const max_length = desc.stat_desc.max_length;
	let h;
	let n, m;
	let bits;
	let xbits;
	let f;
	let overflow = 0;
	for (bits = 0; bits <= MAX_BITS$1; bits++) s.bl_count[bits] = 0;
	tree[s.heap[s.heap_max] * 2 + 1] = 0;
	for (h = s.heap_max + 1; h < HEAP_SIZE$1; h++) {
		n = s.heap[h];
		bits = tree[tree[n * 2 + 1] * 2 + 1] + 1;
		if (bits > max_length) {
			bits = max_length;
			overflow++;
		}
		tree[n * 2 + 1] = bits;
		if (n > max_code) continue;
		s.bl_count[bits]++;
		xbits = 0;
		if (n >= base) xbits = extra[n - base];
		f = tree[n * 2];
		s.opt_len += f * (bits + xbits);
		if (has_stree) s.static_len += f * (stree[n * 2 + 1] + xbits);
	}
	if (overflow === 0) return;
	do {
		bits = max_length - 1;
		while (s.bl_count[bits] === 0) bits--;
		s.bl_count[bits]--;
		s.bl_count[bits + 1] += 2;
		s.bl_count[max_length]--;
		overflow -= 2;
	} while (overflow > 0);
	for (bits = max_length; bits !== 0; bits--) {
		n = s.bl_count[bits];
		while (n !== 0) {
			m = s.heap[--h];
			if (m > max_code) continue;
			if (tree[m * 2 + 1] !== bits) {
				s.opt_len += (bits - tree[m * 2 + 1]) * tree[m * 2];
				tree[m * 2 + 1] = bits;
			}
			n--;
		}
	}
};
const gen_codes = (tree, max_code, bl_count) => {
	const next_code = new Array(MAX_BITS$1 + 1);
	let code = 0;
	let bits;
	let n;
	for (bits = 1; bits <= MAX_BITS$1; bits++) {
		code = code + bl_count[bits - 1] << 1;
		next_code[bits] = code;
	}
	for (n = 0; n <= max_code; n++) {
		let len = tree[n * 2 + 1];
		if (len === 0) continue;
		tree[n * 2] = bi_reverse(next_code[len]++, len);
	}
};
const tr_static_init = () => {
	let n;
	let bits;
	let length;
	let code;
	let dist;
	const bl_count = new Array(MAX_BITS$1 + 1);
	length = 0;
	for (code = 0; code < LENGTH_CODES$1 - 1; code++) {
		base_length[code] = length;
		for (n = 0; n < 1 << extra_lbits[code]; n++) _length_code[length++] = code;
	}
	_length_code[length - 1] = code;
	dist = 0;
	for (code = 0; code < 16; code++) {
		base_dist[code] = dist;
		for (n = 0; n < 1 << extra_dbits[code]; n++) _dist_code[dist++] = code;
	}
	dist >>= 7;
	for (; code < D_CODES$1; code++) {
		base_dist[code] = dist << 7;
		for (n = 0; n < 1 << extra_dbits[code] - 7; n++) _dist_code[256 + dist++] = code;
	}
	for (bits = 0; bits <= MAX_BITS$1; bits++) bl_count[bits] = 0;
	n = 0;
	while (n <= 143) {
		static_ltree[n * 2 + 1] = 8;
		n++;
		bl_count[8]++;
	}
	while (n <= 255) {
		static_ltree[n * 2 + 1] = 9;
		n++;
		bl_count[9]++;
	}
	while (n <= 279) {
		static_ltree[n * 2 + 1] = 7;
		n++;
		bl_count[7]++;
	}
	while (n <= 287) {
		static_ltree[n * 2 + 1] = 8;
		n++;
		bl_count[8]++;
	}
	gen_codes(static_ltree, L_CODES$1 + 1, bl_count);
	for (n = 0; n < D_CODES$1; n++) {
		static_dtree[n * 2 + 1] = 5;
		static_dtree[n * 2] = bi_reverse(n, 5);
	}
	static_l_desc = new StaticTreeDesc(static_ltree, extra_lbits, LITERALS$1 + 1, L_CODES$1, MAX_BITS$1);
	static_d_desc = new StaticTreeDesc(static_dtree, extra_dbits, 0, D_CODES$1, MAX_BITS$1);
	static_bl_desc = new StaticTreeDesc(new Array(0), extra_blbits, 0, BL_CODES$1, MAX_BL_BITS);
};
const init_block = (s) => {
	let n;
	for (n = 0; n < L_CODES$1; n++) s.dyn_ltree[n * 2] = 0;
	for (n = 0; n < D_CODES$1; n++) s.dyn_dtree[n * 2] = 0;
	for (n = 0; n < BL_CODES$1; n++) s.bl_tree[n * 2] = 0;
	s.dyn_ltree[END_BLOCK * 2] = 1;
	s.opt_len = s.static_len = 0;
	s.sym_next = s.matches = 0;
};
const bi_windup = (s) => {
	if (s.bi_valid > 8) put_short(s, s.bi_buf);
	else if (s.bi_valid > 0) s.pending_buf[s.pending++] = s.bi_buf;
	s.bi_buf = 0;
	s.bi_valid = 0;
};
const smaller = (tree, n, m, depth) => {
	const _n2 = n * 2;
	const _m2 = m * 2;
	return tree[_n2] < tree[_m2] || tree[_n2] === tree[_m2] && depth[n] <= depth[m];
};
const pqdownheap = (s, tree, k) => {
	const v = s.heap[k];
	let j = k << 1;
	while (j <= s.heap_len) {
		if (j < s.heap_len && smaller(tree, s.heap[j + 1], s.heap[j], s.depth)) j++;
		if (smaller(tree, v, s.heap[j], s.depth)) break;
		s.heap[k] = s.heap[j];
		k = j;
		j <<= 1;
	}
	s.heap[k] = v;
};
const compress_block = (s, ltree, dtree) => {
	let dist;
	let lc;
	let sx = 0;
	let code;
	let extra;
	if (s.sym_next !== 0) do {
		dist = s.pending_buf[s.sym_buf + sx++] & 255;
		dist += (s.pending_buf[s.sym_buf + sx++] & 255) << 8;
		lc = s.pending_buf[s.sym_buf + sx++];
		if (dist === 0) send_code(s, lc, ltree);
		else {
			code = _length_code[lc];
			send_code(s, code + LITERALS$1 + 1, ltree);
			extra = extra_lbits[code];
			if (extra !== 0) {
				lc -= base_length[code];
				send_bits(s, lc, extra);
			}
			dist--;
			code = d_code(dist);
			send_code(s, code, dtree);
			extra = extra_dbits[code];
			if (extra !== 0) {
				dist -= base_dist[code];
				send_bits(s, dist, extra);
			}
		}
	} while (sx < s.sym_next);
	send_code(s, END_BLOCK, ltree);
};
const build_tree = (s, desc) => {
	const tree = desc.dyn_tree;
	const stree = desc.stat_desc.static_tree;
	const has_stree = desc.stat_desc.has_stree;
	const elems = desc.stat_desc.elems;
	let n, m;
	let max_code = -1;
	let node;
	s.heap_len = 0;
	s.heap_max = HEAP_SIZE$1;
	for (n = 0; n < elems; n++) if (tree[n * 2] !== 0) {
		s.heap[++s.heap_len] = max_code = n;
		s.depth[n] = 0;
	} else tree[n * 2 + 1] = 0;
	while (s.heap_len < 2) {
		node = s.heap[++s.heap_len] = max_code < 2 ? ++max_code : 0;
		tree[node * 2] = 1;
		s.depth[node] = 0;
		s.opt_len--;
		if (has_stree) s.static_len -= stree[node * 2 + 1];
	}
	desc.max_code = max_code;
	for (n = s.heap_len >> 1; n >= 1; n--) pqdownheap(s, tree, n);
	node = elems;
	do {
		/*** pqremove ***/
		n = s.heap[1];
		s.heap[1] = s.heap[s.heap_len--];
		pqdownheap(s, tree, 1);
		m = s.heap[1];
		s.heap[--s.heap_max] = n;
		s.heap[--s.heap_max] = m;
		tree[node * 2] = tree[n * 2] + tree[m * 2];
		s.depth[node] = (s.depth[n] >= s.depth[m] ? s.depth[n] : s.depth[m]) + 1;
		tree[n * 2 + 1] = tree[m * 2 + 1] = node;
		s.heap[1] = node++;
		pqdownheap(s, tree, 1);
	} while (s.heap_len >= 2);
	s.heap[--s.heap_max] = s.heap[1];
	gen_bitlen(s, desc);
	gen_codes(tree, max_code, s.bl_count);
};
const scan_tree = (s, tree, max_code) => {
	let n;
	let prevlen = -1;
	let curlen;
	let nextlen = tree[1];
	let count = 0;
	let max_count = 7;
	let min_count = 4;
	if (nextlen === 0) {
		max_count = 138;
		min_count = 3;
	}
	tree[(max_code + 1) * 2 + 1] = 65535;
	for (n = 0; n <= max_code; n++) {
		curlen = nextlen;
		nextlen = tree[(n + 1) * 2 + 1];
		if (++count < max_count && curlen === nextlen) continue;
		else if (count < min_count) s.bl_tree[curlen * 2] += count;
		else if (curlen !== 0) {
			if (curlen !== prevlen) s.bl_tree[curlen * 2]++;
			s.bl_tree[REP_3_6 * 2]++;
		} else if (count <= 10) s.bl_tree[REPZ_3_10 * 2]++;
		else s.bl_tree[REPZ_11_138 * 2]++;
		count = 0;
		prevlen = curlen;
		if (nextlen === 0) {
			max_count = 138;
			min_count = 3;
		} else if (curlen === nextlen) {
			max_count = 6;
			min_count = 3;
		} else {
			max_count = 7;
			min_count = 4;
		}
	}
};
const send_tree = (s, tree, max_code) => {
	let n;
	let prevlen = -1;
	let curlen;
	let nextlen = tree[1];
	let count = 0;
	let max_count = 7;
	let min_count = 4;
	if (nextlen === 0) {
		max_count = 138;
		min_count = 3;
	}
	for (n = 0; n <= max_code; n++) {
		curlen = nextlen;
		nextlen = tree[(n + 1) * 2 + 1];
		if (++count < max_count && curlen === nextlen) continue;
		else if (count < min_count) do
			send_code(s, curlen, s.bl_tree);
		while (--count !== 0);
		else if (curlen !== 0) {
			if (curlen !== prevlen) {
				send_code(s, curlen, s.bl_tree);
				count--;
			}
			send_code(s, REP_3_6, s.bl_tree);
			send_bits(s, count - 3, 2);
		} else if (count <= 10) {
			send_code(s, REPZ_3_10, s.bl_tree);
			send_bits(s, count - 3, 3);
		} else {
			send_code(s, REPZ_11_138, s.bl_tree);
			send_bits(s, count - 11, 7);
		}
		count = 0;
		prevlen = curlen;
		if (nextlen === 0) {
			max_count = 138;
			min_count = 3;
		} else if (curlen === nextlen) {
			max_count = 6;
			min_count = 3;
		} else {
			max_count = 7;
			min_count = 4;
		}
	}
};
const build_bl_tree = (s) => {
	let max_blindex;
	scan_tree(s, s.dyn_ltree, s.l_desc.max_code);
	scan_tree(s, s.dyn_dtree, s.d_desc.max_code);
	build_tree(s, s.bl_desc);
	for (max_blindex = BL_CODES$1 - 1; max_blindex >= 3; max_blindex--) if (s.bl_tree[bl_order[max_blindex] * 2 + 1] !== 0) break;
	s.opt_len += 3 * (max_blindex + 1) + 5 + 5 + 4;
	return max_blindex;
};
const send_all_trees = (s, lcodes, dcodes, blcodes) => {
	let rank;
	send_bits(s, lcodes - 257, 5);
	send_bits(s, dcodes - 1, 5);
	send_bits(s, blcodes - 4, 4);
	for (rank = 0; rank < blcodes; rank++) send_bits(s, s.bl_tree[bl_order[rank] * 2 + 1], 3);
	send_tree(s, s.dyn_ltree, lcodes - 1);
	send_tree(s, s.dyn_dtree, dcodes - 1);
};
const detect_data_type = (s) => {
	let block_mask = 4093624447;
	let n;
	for (n = 0; n <= 31; n++, block_mask >>>= 1) if (block_mask & 1 && s.dyn_ltree[n * 2] !== 0) return Z_BINARY;
	if (s.dyn_ltree[18] !== 0 || s.dyn_ltree[20] !== 0 || s.dyn_ltree[26] !== 0) return Z_TEXT;
	for (n = 32; n < LITERALS$1; n++) if (s.dyn_ltree[n * 2] !== 0) return Z_TEXT;
	return Z_BINARY;
};
let static_init_done = false;
const _tr_init$1 = (s) => {
	if (!static_init_done) {
		tr_static_init();
		static_init_done = true;
	}
	s.l_desc = new TreeDesc(s.dyn_ltree, static_l_desc);
	s.d_desc = new TreeDesc(s.dyn_dtree, static_d_desc);
	s.bl_desc = new TreeDesc(s.bl_tree, static_bl_desc);
	s.bi_buf = 0;
	s.bi_valid = 0;
	init_block(s);
};
const _tr_stored_block$1 = (s, buf, stored_len, last) => {
	send_bits(s, (STORED_BLOCK << 1) + (last ? 1 : 0), 3);
	bi_windup(s);
	put_short(s, stored_len);
	put_short(s, ~stored_len);
	if (stored_len) s.pending_buf.set(s.window.subarray(buf, buf + stored_len), s.pending);
	s.pending += stored_len;
};
const _tr_align$1 = (s) => {
	send_bits(s, STATIC_TREES << 1, 3);
	send_code(s, END_BLOCK, static_ltree);
	bi_flush(s);
};
const _tr_flush_block$1 = (s, buf, stored_len, last) => {
	let opt_lenb, static_lenb;
	let max_blindex = 0;
	if (s.level > 0) {
		if (s.strm.data_type === Z_UNKNOWN$1) s.strm.data_type = detect_data_type(s);
		build_tree(s, s.l_desc);
		build_tree(s, s.d_desc);
		max_blindex = build_bl_tree(s);
		opt_lenb = s.opt_len + 3 + 7 >>> 3;
		static_lenb = s.static_len + 3 + 7 >>> 3;
		if (static_lenb <= opt_lenb) opt_lenb = static_lenb;
	} else opt_lenb = static_lenb = stored_len + 5;
	if (stored_len + 4 <= opt_lenb && buf !== -1) _tr_stored_block$1(s, buf, stored_len, last);
	else if (s.strategy === Z_FIXED$1 || static_lenb === opt_lenb) {
		send_bits(s, (STATIC_TREES << 1) + (last ? 1 : 0), 3);
		compress_block(s, static_ltree, static_dtree);
	} else {
		send_bits(s, (DYN_TREES << 1) + (last ? 1 : 0), 3);
		send_all_trees(s, s.l_desc.max_code + 1, s.d_desc.max_code + 1, max_blindex + 1);
		compress_block(s, s.dyn_ltree, s.dyn_dtree);
	}
	init_block(s);
	if (last) bi_windup(s);
};
const _tr_tally$1 = (s, dist, lc) => {
	s.pending_buf[s.sym_buf + s.sym_next++] = dist;
	s.pending_buf[s.sym_buf + s.sym_next++] = dist >> 8;
	s.pending_buf[s.sym_buf + s.sym_next++] = lc;
	if (dist === 0) s.dyn_ltree[lc * 2]++;
	else {
		s.matches++;
		dist--;
		s.dyn_ltree[(_length_code[lc] + LITERALS$1 + 1) * 2]++;
		s.dyn_dtree[d_code(dist) * 2]++;
	}
	return s.sym_next === s.sym_end;
};
var trees = {
	_tr_init: _tr_init$1,
	_tr_stored_block: _tr_stored_block$1,
	_tr_flush_block: _tr_flush_block$1,
	_tr_tally: _tr_tally$1,
	_tr_align: _tr_align$1
};
const adler32 = (adler, buf, len, pos) => {
	let s1 = adler & 65535 | 0, s2 = adler >>> 16 & 65535 | 0, n = 0;
	while (len !== 0) {
		n = len > 2e3 ? 2e3 : len;
		len -= n;
		do {
			s1 = s1 + buf[pos++] | 0;
			s2 = s2 + s1 | 0;
		} while (--n);
		s1 %= 65521;
		s2 %= 65521;
	}
	return s1 | s2 << 16 | 0;
};
var adler32_1 = adler32;
const makeTable = () => {
	let c, table = [];
	for (var n = 0; n < 256; n++) {
		c = n;
		for (var k = 0; k < 8; k++) c = c & 1 ? 3988292384 ^ c >>> 1 : c >>> 1;
		table[n] = c;
	}
	return table;
};
const crcTable = new Uint32Array(makeTable());
const crc32 = (crc, buf, len, pos) => {
	const t = crcTable;
	const end = pos + len;
	crc ^= -1;
	for (let i = pos; i < end; i++) crc = crc >>> 8 ^ t[(crc ^ buf[i]) & 255];
	return crc ^ -1;
};
var crc32_1 = crc32;
var messages = {
	2: "need dictionary",
	1: "stream end",
	0: "",
	"-1": "file error",
	"-2": "stream error",
	"-3": "data error",
	"-4": "insufficient memory",
	"-5": "buffer error",
	"-6": "incompatible version"
};
var constants$2 = {
	Z_NO_FLUSH: 0,
	Z_PARTIAL_FLUSH: 1,
	Z_SYNC_FLUSH: 2,
	Z_FULL_FLUSH: 3,
	Z_FINISH: 4,
	Z_BLOCK: 5,
	Z_TREES: 6,
	Z_OK: 0,
	Z_STREAM_END: 1,
	Z_NEED_DICT: 2,
	Z_ERRNO: -1,
	Z_STREAM_ERROR: -2,
	Z_DATA_ERROR: -3,
	Z_MEM_ERROR: -4,
	Z_BUF_ERROR: -5,
	Z_NO_COMPRESSION: 0,
	Z_BEST_SPEED: 1,
	Z_BEST_COMPRESSION: 9,
	Z_DEFAULT_COMPRESSION: -1,
	Z_FILTERED: 1,
	Z_HUFFMAN_ONLY: 2,
	Z_RLE: 3,
	Z_FIXED: 4,
	Z_DEFAULT_STRATEGY: 0,
	Z_BINARY: 0,
	Z_TEXT: 1,
	Z_UNKNOWN: 2,
	Z_DEFLATED: 8
};
const { _tr_init, _tr_stored_block, _tr_flush_block, _tr_tally, _tr_align } = trees;
const { Z_NO_FLUSH: Z_NO_FLUSH$2, Z_PARTIAL_FLUSH, Z_FULL_FLUSH: Z_FULL_FLUSH$1, Z_FINISH: Z_FINISH$3, Z_BLOCK: Z_BLOCK$1, Z_OK: Z_OK$3, Z_STREAM_END: Z_STREAM_END$3, Z_STREAM_ERROR: Z_STREAM_ERROR$2, Z_DATA_ERROR: Z_DATA_ERROR$2, Z_BUF_ERROR: Z_BUF_ERROR$1, Z_DEFAULT_COMPRESSION: Z_DEFAULT_COMPRESSION$1, Z_FILTERED, Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED, Z_DEFAULT_STRATEGY: Z_DEFAULT_STRATEGY$1, Z_UNKNOWN, Z_DEFLATED: Z_DEFLATED$2 } = constants$2;
const MAX_MEM_LEVEL = 9;
const MAX_WBITS$1 = 15;
const DEF_MEM_LEVEL = 8;
const L_CODES = 286;
const D_CODES = 30;
const BL_CODES = 19;
const HEAP_SIZE = 2 * L_CODES + 1;
const MAX_BITS = 15;
const MIN_MATCH = 3;
const MAX_MATCH = 258;
const MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1;
const PRESET_DICT = 32;
const INIT_STATE = 42;
const GZIP_STATE = 57;
const EXTRA_STATE = 69;
const NAME_STATE = 73;
const COMMENT_STATE = 91;
const HCRC_STATE = 103;
const BUSY_STATE = 113;
const FINISH_STATE = 666;
const BS_NEED_MORE = 1;
const BS_BLOCK_DONE = 2;
const BS_FINISH_STARTED = 3;
const BS_FINISH_DONE = 4;
const OS_CODE = 3;
const err = (strm, errorCode) => {
	strm.msg = messages[errorCode];
	return errorCode;
};
const rank = (f) => {
	return f * 2 - (f > 4 ? 9 : 0);
};
const zero = (buf) => {
	let len = buf.length;
	while (--len >= 0) buf[len] = 0;
};
const slide_hash = (s) => {
	let n, m;
	let p;
	let wsize = s.w_size;
	n = s.hash_size;
	p = n;
	do {
		m = s.head[--p];
		s.head[p] = m >= wsize ? m - wsize : 0;
	} while (--n);
	n = wsize;
	p = n;
	do {
		m = s.prev[--p];
		s.prev[p] = m >= wsize ? m - wsize : 0;
	} while (--n);
};
let HASH_ZLIB = (s, prev, data) => (prev << s.hash_shift ^ data) & s.hash_mask;
let HASH = HASH_ZLIB;
const flush_pending = (strm) => {
	const s = strm.state;
	let len = s.pending;
	if (len > strm.avail_out) len = strm.avail_out;
	if (len === 0) return;
	strm.output.set(s.pending_buf.subarray(s.pending_out, s.pending_out + len), strm.next_out);
	strm.next_out += len;
	s.pending_out += len;
	strm.total_out += len;
	strm.avail_out -= len;
	s.pending -= len;
	if (s.pending === 0) s.pending_out = 0;
};
const flush_block_only = (s, last) => {
	_tr_flush_block(s, s.block_start >= 0 ? s.block_start : -1, s.strstart - s.block_start, last);
	s.block_start = s.strstart;
	flush_pending(s.strm);
};
const put_byte = (s, b) => {
	s.pending_buf[s.pending++] = b;
};
const putShortMSB = (s, b) => {
	s.pending_buf[s.pending++] = b >>> 8 & 255;
	s.pending_buf[s.pending++] = b & 255;
};
const read_buf = (strm, buf, start, size) => {
	let len = strm.avail_in;
	if (len > size) len = size;
	if (len === 0) return 0;
	strm.avail_in -= len;
	buf.set(strm.input.subarray(strm.next_in, strm.next_in + len), start);
	if (strm.state.wrap === 1) strm.adler = adler32_1(strm.adler, buf, len, start);
	else if (strm.state.wrap === 2) strm.adler = crc32_1(strm.adler, buf, len, start);
	strm.next_in += len;
	strm.total_in += len;
	return len;
};
const longest_match = (s, cur_match) => {
	let chain_length = s.max_chain_length;
	let scan = s.strstart;
	let match;
	let len;
	let best_len = s.prev_length;
	let nice_match = s.nice_match;
	const limit = s.strstart > s.w_size - MIN_LOOKAHEAD ? s.strstart - (s.w_size - MIN_LOOKAHEAD) : 0;
	const _win = s.window;
	const wmask = s.w_mask;
	const prev = s.prev;
	const strend = s.strstart + MAX_MATCH;
	let scan_end1 = _win[scan + best_len - 1];
	let scan_end = _win[scan + best_len];
	if (s.prev_length >= s.good_match) chain_length >>= 2;
	if (nice_match > s.lookahead) nice_match = s.lookahead;
	do {
		match = cur_match;
		if (_win[match + best_len] !== scan_end || _win[match + best_len - 1] !== scan_end1 || _win[match] !== _win[scan] || _win[++match] !== _win[scan + 1]) continue;
		scan += 2;
		match++;
		do		;
while (_win[++scan] === _win[++match] && _win[++scan] === _win[++match] && _win[++scan] === _win[++match] && _win[++scan] === _win[++match] && _win[++scan] === _win[++match] && _win[++scan] === _win[++match] && _win[++scan] === _win[++match] && _win[++scan] === _win[++match] && scan < strend);
		len = MAX_MATCH - (strend - scan);
		scan = strend - MAX_MATCH;
		if (len > best_len) {
			s.match_start = cur_match;
			best_len = len;
			if (len >= nice_match) break;
			scan_end1 = _win[scan + best_len - 1];
			scan_end = _win[scan + best_len];
		}
	} while ((cur_match = prev[cur_match & wmask]) > limit && --chain_length !== 0);
	if (best_len <= s.lookahead) return best_len;
	return s.lookahead;
};
const fill_window = (s) => {
	const _w_size = s.w_size;
	let n, more, str;
	do {
		more = s.window_size - s.lookahead - s.strstart;
		if (s.strstart >= _w_size + (_w_size - MIN_LOOKAHEAD)) {
			s.window.set(s.window.subarray(_w_size, _w_size + _w_size - more), 0);
			s.match_start -= _w_size;
			s.strstart -= _w_size;
			s.block_start -= _w_size;
			if (s.insert > s.strstart) s.insert = s.strstart;
			slide_hash(s);
			more += _w_size;
		}
		if (s.strm.avail_in === 0) break;
		n = read_buf(s.strm, s.window, s.strstart + s.lookahead, more);
		s.lookahead += n;
		if (s.lookahead + s.insert >= MIN_MATCH) {
			str = s.strstart - s.insert;
			s.ins_h = s.window[str];
			s.ins_h = HASH(s, s.ins_h, s.window[str + 1]);
			while (s.insert) {
				s.ins_h = HASH(s, s.ins_h, s.window[str + MIN_MATCH - 1]);
				s.prev[str & s.w_mask] = s.head[s.ins_h];
				s.head[s.ins_h] = str;
				str++;
				s.insert--;
				if (s.lookahead + s.insert < MIN_MATCH) break;
			}
		}
	} while (s.lookahead < MIN_LOOKAHEAD && s.strm.avail_in !== 0);
};
const deflate_stored = (s, flush) => {
	let min_block = s.pending_buf_size - 5 > s.w_size ? s.w_size : s.pending_buf_size - 5;
	let len, left, have, last = 0;
	let used = s.strm.avail_in;
	do {
		len = 65535;
		have = s.bi_valid + 42 >> 3;
		if (s.strm.avail_out < have) break;
		have = s.strm.avail_out - have;
		left = s.strstart - s.block_start;
		if (len > left + s.strm.avail_in) len = left + s.strm.avail_in;
		if (len > have) len = have;
		if (len < min_block && (len === 0 && flush !== Z_FINISH$3 || flush === Z_NO_FLUSH$2 || len !== left + s.strm.avail_in)) break;
		last = flush === Z_FINISH$3 && len === left + s.strm.avail_in ? 1 : 0;
		_tr_stored_block(s, 0, 0, last);
		s.pending_buf[s.pending - 4] = len;
		s.pending_buf[s.pending - 3] = len >> 8;
		s.pending_buf[s.pending - 2] = ~len;
		s.pending_buf[s.pending - 1] = ~len >> 8;
		flush_pending(s.strm);
		if (left) {
			if (left > len) left = len;
			s.strm.output.set(s.window.subarray(s.block_start, s.block_start + left), s.strm.next_out);
			s.strm.next_out += left;
			s.strm.avail_out -= left;
			s.strm.total_out += left;
			s.block_start += left;
			len -= left;
		}
		if (len) {
			read_buf(s.strm, s.strm.output, s.strm.next_out, len);
			s.strm.next_out += len;
			s.strm.avail_out -= len;
			s.strm.total_out += len;
		}
	} while (last === 0);
	used -= s.strm.avail_in;
	if (used) {
		if (used >= s.w_size) {
			s.matches = 2;
			s.window.set(s.strm.input.subarray(s.strm.next_in - s.w_size, s.strm.next_in), 0);
			s.strstart = s.w_size;
			s.insert = s.strstart;
		} else {
			if (s.window_size - s.strstart <= used) {
				s.strstart -= s.w_size;
				s.window.set(s.window.subarray(s.w_size, s.w_size + s.strstart), 0);
				if (s.matches < 2) s.matches++;
				if (s.insert > s.strstart) s.insert = s.strstart;
			}
			s.window.set(s.strm.input.subarray(s.strm.next_in - used, s.strm.next_in), s.strstart);
			s.strstart += used;
			s.insert += used > s.w_size - s.insert ? s.w_size - s.insert : used;
		}
		s.block_start = s.strstart;
	}
	if (s.high_water < s.strstart) s.high_water = s.strstart;
	if (last) return BS_FINISH_DONE;
	if (flush !== Z_NO_FLUSH$2 && flush !== Z_FINISH$3 && s.strm.avail_in === 0 && s.strstart === s.block_start) return BS_BLOCK_DONE;
	have = s.window_size - s.strstart;
	if (s.strm.avail_in > have && s.block_start >= s.w_size) {
		s.block_start -= s.w_size;
		s.strstart -= s.w_size;
		s.window.set(s.window.subarray(s.w_size, s.w_size + s.strstart), 0);
		if (s.matches < 2) s.matches++;
		have += s.w_size;
		if (s.insert > s.strstart) s.insert = s.strstart;
	}
	if (have > s.strm.avail_in) have = s.strm.avail_in;
	if (have) {
		read_buf(s.strm, s.window, s.strstart, have);
		s.strstart += have;
		s.insert += have > s.w_size - s.insert ? s.w_size - s.insert : have;
	}
	if (s.high_water < s.strstart) s.high_water = s.strstart;
	have = s.bi_valid + 42 >> 3;
	have = s.pending_buf_size - have > 65535 ? 65535 : s.pending_buf_size - have;
	min_block = have > s.w_size ? s.w_size : have;
	left = s.strstart - s.block_start;
	if (left >= min_block || (left || flush === Z_FINISH$3) && flush !== Z_NO_FLUSH$2 && s.strm.avail_in === 0 && left <= have) {
		len = left > have ? have : left;
		last = flush === Z_FINISH$3 && s.strm.avail_in === 0 && len === left ? 1 : 0;
		_tr_stored_block(s, s.block_start, len, last);
		s.block_start += len;
		flush_pending(s.strm);
	}
	return last ? BS_FINISH_STARTED : BS_NEED_MORE;
};
const deflate_fast = (s, flush) => {
	let hash_head;
	let bflush;
	for (;;) {
		if (s.lookahead < MIN_LOOKAHEAD) {
			fill_window(s);
			if (s.lookahead < MIN_LOOKAHEAD && flush === Z_NO_FLUSH$2) return BS_NEED_MORE;
			if (s.lookahead === 0) break;
		}
		hash_head = 0;
		if (s.lookahead >= MIN_MATCH) {
			/*** INSERT_STRING(s, s.strstart, hash_head); ***/
			s.ins_h = HASH(s, s.ins_h, s.window[s.strstart + MIN_MATCH - 1]);
			hash_head = s.prev[s.strstart & s.w_mask] = s.head[s.ins_h];
			s.head[s.ins_h] = s.strstart;
		}
		if (hash_head !== 0 && s.strstart - hash_head <= s.w_size - MIN_LOOKAHEAD) s.match_length = longest_match(s, hash_head);
		if (s.match_length >= MIN_MATCH) {
			/*** _tr_tally_dist(s, s.strstart - s.match_start,
			s.match_length - MIN_MATCH, bflush); ***/
			bflush = _tr_tally(s, s.strstart - s.match_start, s.match_length - MIN_MATCH);
			s.lookahead -= s.match_length;
			if (s.match_length <= s.max_lazy_match && s.lookahead >= MIN_MATCH) {
				s.match_length--;
				do {
					s.strstart++;
					/*** INSERT_STRING(s, s.strstart, hash_head); ***/
					s.ins_h = HASH(s, s.ins_h, s.window[s.strstart + MIN_MATCH - 1]);
					hash_head = s.prev[s.strstart & s.w_mask] = s.head[s.ins_h];
					s.head[s.ins_h] = s.strstart;
				} while (--s.match_length !== 0);
				s.strstart++;
			} else {
				s.strstart += s.match_length;
				s.match_length = 0;
				s.ins_h = s.window[s.strstart];
				s.ins_h = HASH(s, s.ins_h, s.window[s.strstart + 1]);
			}
		} else {
			/*** _tr_tally_lit(s, s.window[s.strstart], bflush); ***/
			bflush = _tr_tally(s, 0, s.window[s.strstart]);
			s.lookahead--;
			s.strstart++;
		}
		if (bflush) {
			/*** FLUSH_BLOCK(s, 0); ***/
			flush_block_only(s, false);
			if (s.strm.avail_out === 0) return BS_NEED_MORE;
		}
	}
	s.insert = s.strstart < MIN_MATCH - 1 ? s.strstart : MIN_MATCH - 1;
	if (flush === Z_FINISH$3) {
		/*** FLUSH_BLOCK(s, 1); ***/
		flush_block_only(s, true);
		if (s.strm.avail_out === 0) return BS_FINISH_STARTED;
		return BS_FINISH_DONE;
	}
	if (s.sym_next) {
		/*** FLUSH_BLOCK(s, 0); ***/
		flush_block_only(s, false);
		if (s.strm.avail_out === 0) return BS_NEED_MORE;
	}
	return BS_BLOCK_DONE;
};
const deflate_slow = (s, flush) => {
	let hash_head;
	let bflush;
	let max_insert;
	for (;;) {
		if (s.lookahead < MIN_LOOKAHEAD) {
			fill_window(s);
			if (s.lookahead < MIN_LOOKAHEAD && flush === Z_NO_FLUSH$2) return BS_NEED_MORE;
			if (s.lookahead === 0) break;
		}
		hash_head = 0;
		if (s.lookahead >= MIN_MATCH) {
			/*** INSERT_STRING(s, s.strstart, hash_head); ***/
			s.ins_h = HASH(s, s.ins_h, s.window[s.strstart + MIN_MATCH - 1]);
			hash_head = s.prev[s.strstart & s.w_mask] = s.head[s.ins_h];
			s.head[s.ins_h] = s.strstart;
		}
		s.prev_length = s.match_length;
		s.prev_match = s.match_start;
		s.match_length = MIN_MATCH - 1;
		if (hash_head !== 0 && s.prev_length < s.max_lazy_match && s.strstart - hash_head <= s.w_size - MIN_LOOKAHEAD) {
			s.match_length = longest_match(s, hash_head);
			if (s.match_length <= 5 && (s.strategy === Z_FILTERED || s.match_length === MIN_MATCH && s.strstart - s.match_start > 4096)) s.match_length = MIN_MATCH - 1;
		}
		if (s.prev_length >= MIN_MATCH && s.match_length <= s.prev_length) {
			max_insert = s.strstart + s.lookahead - MIN_MATCH;
			/***_tr_tally_dist(s, s.strstart - 1 - s.prev_match,
			s.prev_length - MIN_MATCH, bflush);***/
			bflush = _tr_tally(s, s.strstart - 1 - s.prev_match, s.prev_length - MIN_MATCH);
			s.lookahead -= s.prev_length - 1;
			s.prev_length -= 2;
			do
				if (++s.strstart <= max_insert) {
					/*** INSERT_STRING(s, s.strstart, hash_head); ***/
					s.ins_h = HASH(s, s.ins_h, s.window[s.strstart + MIN_MATCH - 1]);
					hash_head = s.prev[s.strstart & s.w_mask] = s.head[s.ins_h];
					s.head[s.ins_h] = s.strstart;
				}
			while (--s.prev_length !== 0);
			s.match_available = 0;
			s.match_length = MIN_MATCH - 1;
			s.strstart++;
			if (bflush) {
				/*** FLUSH_BLOCK(s, 0); ***/
				flush_block_only(s, false);
				if (s.strm.avail_out === 0) return BS_NEED_MORE;
			}
		} else if (s.match_available) {
			/*** _tr_tally_lit(s, s.window[s.strstart-1], bflush); ***/
			bflush = _tr_tally(s, 0, s.window[s.strstart - 1]);
			if (bflush)
 /*** FLUSH_BLOCK_ONLY(s, 0) ***/
			flush_block_only(s, false);
			s.strstart++;
			s.lookahead--;
			if (s.strm.avail_out === 0) return BS_NEED_MORE;
		} else {
			s.match_available = 1;
			s.strstart++;
			s.lookahead--;
		}
	}
	if (s.match_available) {
		/*** _tr_tally_lit(s, s.window[s.strstart-1], bflush); ***/
		bflush = _tr_tally(s, 0, s.window[s.strstart - 1]);
		s.match_available = 0;
	}
	s.insert = s.strstart < MIN_MATCH - 1 ? s.strstart : MIN_MATCH - 1;
	if (flush === Z_FINISH$3) {
		/*** FLUSH_BLOCK(s, 1); ***/
		flush_block_only(s, true);
		if (s.strm.avail_out === 0) return BS_FINISH_STARTED;
		return BS_FINISH_DONE;
	}
	if (s.sym_next) {
		/*** FLUSH_BLOCK(s, 0); ***/
		flush_block_only(s, false);
		if (s.strm.avail_out === 0) return BS_NEED_MORE;
	}
	return BS_BLOCK_DONE;
};
const deflate_rle = (s, flush) => {
	let bflush;
	let prev;
	let scan, strend;
	const _win = s.window;
	for (;;) {
		if (s.lookahead <= MAX_MATCH) {
			fill_window(s);
			if (s.lookahead <= MAX_MATCH && flush === Z_NO_FLUSH$2) return BS_NEED_MORE;
			if (s.lookahead === 0) break;
		}
		s.match_length = 0;
		if (s.lookahead >= MIN_MATCH && s.strstart > 0) {
			scan = s.strstart - 1;
			prev = _win[scan];
			if (prev === _win[++scan] && prev === _win[++scan] && prev === _win[++scan]) {
				strend = s.strstart + MAX_MATCH;
				do				;
while (prev === _win[++scan] && prev === _win[++scan] && prev === _win[++scan] && prev === _win[++scan] && prev === _win[++scan] && prev === _win[++scan] && prev === _win[++scan] && prev === _win[++scan] && scan < strend);
				s.match_length = MAX_MATCH - (strend - scan);
				if (s.match_length > s.lookahead) s.match_length = s.lookahead;
			}
		}
		if (s.match_length >= MIN_MATCH) {
			/*** _tr_tally_dist(s, 1, s.match_length - MIN_MATCH, bflush); ***/
			bflush = _tr_tally(s, 1, s.match_length - MIN_MATCH);
			s.lookahead -= s.match_length;
			s.strstart += s.match_length;
			s.match_length = 0;
		} else {
			/*** _tr_tally_lit(s, s.window[s.strstart], bflush); ***/
			bflush = _tr_tally(s, 0, s.window[s.strstart]);
			s.lookahead--;
			s.strstart++;
		}
		if (bflush) {
			/*** FLUSH_BLOCK(s, 0); ***/
			flush_block_only(s, false);
			if (s.strm.avail_out === 0) return BS_NEED_MORE;
		}
	}
	s.insert = 0;
	if (flush === Z_FINISH$3) {
		/*** FLUSH_BLOCK(s, 1); ***/
		flush_block_only(s, true);
		if (s.strm.avail_out === 0) return BS_FINISH_STARTED;
		return BS_FINISH_DONE;
	}
	if (s.sym_next) {
		/*** FLUSH_BLOCK(s, 0); ***/
		flush_block_only(s, false);
		if (s.strm.avail_out === 0) return BS_NEED_MORE;
	}
	return BS_BLOCK_DONE;
};
const deflate_huff = (s, flush) => {
	let bflush;
	for (;;) {
		if (s.lookahead === 0) {
			fill_window(s);
			if (s.lookahead === 0) {
				if (flush === Z_NO_FLUSH$2) return BS_NEED_MORE;
				break;
			}
		}
		s.match_length = 0;
		/*** _tr_tally_lit(s, s.window[s.strstart], bflush); ***/
		bflush = _tr_tally(s, 0, s.window[s.strstart]);
		s.lookahead--;
		s.strstart++;
		if (bflush) {
			/*** FLUSH_BLOCK(s, 0); ***/
			flush_block_only(s, false);
			if (s.strm.avail_out === 0) return BS_NEED_MORE;
		}
	}
	s.insert = 0;
	if (flush === Z_FINISH$3) {
		/*** FLUSH_BLOCK(s, 1); ***/
		flush_block_only(s, true);
		if (s.strm.avail_out === 0) return BS_FINISH_STARTED;
		return BS_FINISH_DONE;
	}
	if (s.sym_next) {
		/*** FLUSH_BLOCK(s, 0); ***/
		flush_block_only(s, false);
		if (s.strm.avail_out === 0) return BS_NEED_MORE;
	}
	return BS_BLOCK_DONE;
};
function Config(good_length, max_lazy, nice_length, max_chain, func) {
	this.good_length = good_length;
	this.max_lazy = max_lazy;
	this.nice_length = nice_length;
	this.max_chain = max_chain;
	this.func = func;
}
const configuration_table = [
	new Config(0, 0, 0, 0, deflate_stored),
	new Config(4, 4, 8, 4, deflate_fast),
	new Config(4, 5, 16, 8, deflate_fast),
	new Config(4, 6, 32, 32, deflate_fast),
	new Config(4, 4, 16, 16, deflate_slow),
	new Config(8, 16, 32, 32, deflate_slow),
	new Config(8, 16, 128, 128, deflate_slow),
	new Config(8, 32, 128, 256, deflate_slow),
	new Config(32, 128, 258, 1024, deflate_slow),
	new Config(32, 258, 258, 4096, deflate_slow)
];
const lm_init = (s) => {
	s.window_size = 2 * s.w_size;
	/*** CLEAR_HASH(s); ***/
	zero(s.head);
	s.max_lazy_match = configuration_table[s.level].max_lazy;
	s.good_match = configuration_table[s.level].good_length;
	s.nice_match = configuration_table[s.level].nice_length;
	s.max_chain_length = configuration_table[s.level].max_chain;
	s.strstart = 0;
	s.block_start = 0;
	s.lookahead = 0;
	s.insert = 0;
	s.match_length = s.prev_length = MIN_MATCH - 1;
	s.match_available = 0;
	s.ins_h = 0;
};
function DeflateState() {
	this.strm = null;
	this.status = 0;
	this.pending_buf = null;
	this.pending_buf_size = 0;
	this.pending_out = 0;
	this.pending = 0;
	this.wrap = 0;
	this.gzhead = null;
	this.gzindex = 0;
	this.method = Z_DEFLATED$2;
	this.last_flush = -1;
	this.w_size = 0;
	this.w_bits = 0;
	this.w_mask = 0;
	this.window = null;
	this.window_size = 0;
	this.prev = null;
	this.head = null;
	this.ins_h = 0;
	this.hash_size = 0;
	this.hash_bits = 0;
	this.hash_mask = 0;
	this.hash_shift = 0;
	this.block_start = 0;
	this.match_length = 0;
	this.prev_match = 0;
	this.match_available = 0;
	this.strstart = 0;
	this.match_start = 0;
	this.lookahead = 0;
	this.prev_length = 0;
	this.max_chain_length = 0;
	this.max_lazy_match = 0;
	this.level = 0;
	this.strategy = 0;
	this.good_match = 0;
	this.nice_match = 0;
	this.dyn_ltree = new Uint16Array(HEAP_SIZE * 2);
	this.dyn_dtree = new Uint16Array((2 * D_CODES + 1) * 2);
	this.bl_tree = new Uint16Array((2 * BL_CODES + 1) * 2);
	zero(this.dyn_ltree);
	zero(this.dyn_dtree);
	zero(this.bl_tree);
	this.l_desc = null;
	this.d_desc = null;
	this.bl_desc = null;
	this.bl_count = new Uint16Array(MAX_BITS + 1);
	this.heap = new Uint16Array(2 * L_CODES + 1);
	zero(this.heap);
	this.heap_len = 0;
	this.heap_max = 0;
	this.depth = new Uint16Array(2 * L_CODES + 1);
	zero(this.depth);
	this.sym_buf = 0;
	this.lit_bufsize = 0;
	this.sym_next = 0;
	this.sym_end = 0;
	this.opt_len = 0;
	this.static_len = 0;
	this.matches = 0;
	this.insert = 0;
	this.bi_buf = 0;
	this.bi_valid = 0;
}
const deflateStateCheck = (strm) => {
	if (!strm) return 1;
	const s = strm.state;
	if (!s || s.strm !== strm || s.status !== INIT_STATE && s.status !== GZIP_STATE && s.status !== EXTRA_STATE && s.status !== NAME_STATE && s.status !== COMMENT_STATE && s.status !== HCRC_STATE && s.status !== BUSY_STATE && s.status !== FINISH_STATE) return 1;
	return 0;
};
const deflateResetKeep = (strm) => {
	if (deflateStateCheck(strm)) return err(strm, Z_STREAM_ERROR$2);
	strm.total_in = strm.total_out = 0;
	strm.data_type = Z_UNKNOWN;
	const s = strm.state;
	s.pending = 0;
	s.pending_out = 0;
	if (s.wrap < 0) s.wrap = -s.wrap;
	s.status = s.wrap === 2 ? GZIP_STATE : s.wrap ? INIT_STATE : BUSY_STATE;
	strm.adler = s.wrap === 2 ? 0 : 1;
	s.last_flush = -2;
	_tr_init(s);
	return Z_OK$3;
};
const deflateReset = (strm) => {
	const ret = deflateResetKeep(strm);
	if (ret === Z_OK$3) lm_init(strm.state);
	return ret;
};
const deflateSetHeader = (strm, head) => {
	if (deflateStateCheck(strm) || strm.state.wrap !== 2) return Z_STREAM_ERROR$2;
	strm.state.gzhead = head;
	return Z_OK$3;
};
const deflateInit2 = (strm, level, method, windowBits, memLevel, strategy) => {
	if (!strm) return Z_STREAM_ERROR$2;
	let wrap = 1;
	if (level === Z_DEFAULT_COMPRESSION$1) level = 6;
	if (windowBits < 0) {
		wrap = 0;
		windowBits = -windowBits;
	} else if (windowBits > 15) {
		wrap = 2;
		windowBits -= 16;
	}
	if (memLevel < 1 || memLevel > MAX_MEM_LEVEL || method !== Z_DEFLATED$2 || windowBits < 8 || windowBits > 15 || level < 0 || level > 9 || strategy < 0 || strategy > Z_FIXED || windowBits === 8 && wrap !== 1) return err(strm, Z_STREAM_ERROR$2);
	if (windowBits === 8) windowBits = 9;
	const s = new DeflateState();
	strm.state = s;
	s.strm = strm;
	s.status = INIT_STATE;
	s.wrap = wrap;
	s.gzhead = null;
	s.w_bits = windowBits;
	s.w_size = 1 << s.w_bits;
	s.w_mask = s.w_size - 1;
	s.hash_bits = memLevel + 7;
	s.hash_size = 1 << s.hash_bits;
	s.hash_mask = s.hash_size - 1;
	s.hash_shift = ~~((s.hash_bits + MIN_MATCH - 1) / MIN_MATCH);
	s.window = new Uint8Array(s.w_size * 2);
	s.head = new Uint16Array(s.hash_size);
	s.prev = new Uint16Array(s.w_size);
	s.lit_bufsize = 1 << memLevel + 6;
	s.pending_buf_size = s.lit_bufsize * 4;
	s.pending_buf = new Uint8Array(s.pending_buf_size);
	s.sym_buf = s.lit_bufsize;
	s.sym_end = (s.lit_bufsize - 1) * 3;
	s.level = level;
	s.strategy = strategy;
	s.method = method;
	return deflateReset(strm);
};
const deflateInit = (strm, level) => {
	return deflateInit2(strm, level, Z_DEFLATED$2, MAX_WBITS$1, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY$1);
};
const deflate$2 = (strm, flush) => {
	if (deflateStateCheck(strm) || flush > Z_BLOCK$1 || flush < 0) return strm ? err(strm, Z_STREAM_ERROR$2) : Z_STREAM_ERROR$2;
	const s = strm.state;
	if (!strm.output || strm.avail_in !== 0 && !strm.input || s.status === FINISH_STATE && flush !== Z_FINISH$3) return err(strm, strm.avail_out === 0 ? Z_BUF_ERROR$1 : Z_STREAM_ERROR$2);
	const old_flush = s.last_flush;
	s.last_flush = flush;
	if (s.pending !== 0) {
		flush_pending(strm);
		if (strm.avail_out === 0) {
			s.last_flush = -1;
			return Z_OK$3;
		}
	} else if (strm.avail_in === 0 && rank(flush) <= rank(old_flush) && flush !== Z_FINISH$3) return err(strm, Z_BUF_ERROR$1);
	if (s.status === FINISH_STATE && strm.avail_in !== 0) return err(strm, Z_BUF_ERROR$1);
	if (s.status === INIT_STATE && s.wrap === 0) s.status = BUSY_STATE;
	if (s.status === INIT_STATE) {
		let header = Z_DEFLATED$2 + (s.w_bits - 8 << 4) << 8;
		let level_flags = -1;
		if (s.strategy >= Z_HUFFMAN_ONLY || s.level < 2) level_flags = 0;
		else if (s.level < 6) level_flags = 1;
		else if (s.level === 6) level_flags = 2;
		else level_flags = 3;
		header |= level_flags << 6;
		if (s.strstart !== 0) header |= PRESET_DICT;
		header += 31 - header % 31;
		putShortMSB(s, header);
		if (s.strstart !== 0) {
			putShortMSB(s, strm.adler >>> 16);
			putShortMSB(s, strm.adler & 65535);
		}
		strm.adler = 1;
		s.status = BUSY_STATE;
		flush_pending(strm);
		if (s.pending !== 0) {
			s.last_flush = -1;
			return Z_OK$3;
		}
	}
	if (s.status === GZIP_STATE) {
		strm.adler = 0;
		put_byte(s, 31);
		put_byte(s, 139);
		put_byte(s, 8);
		if (!s.gzhead) {
			put_byte(s, 0);
			put_byte(s, 0);
			put_byte(s, 0);
			put_byte(s, 0);
			put_byte(s, 0);
			put_byte(s, s.level === 9 ? 2 : s.strategy >= Z_HUFFMAN_ONLY || s.level < 2 ? 4 : 0);
			put_byte(s, OS_CODE);
			s.status = BUSY_STATE;
			flush_pending(strm);
			if (s.pending !== 0) {
				s.last_flush = -1;
				return Z_OK$3;
			}
		} else {
			put_byte(s, (s.gzhead.text ? 1 : 0) + (s.gzhead.hcrc ? 2 : 0) + (!s.gzhead.extra ? 0 : 4) + (!s.gzhead.name ? 0 : 8) + (!s.gzhead.comment ? 0 : 16));
			put_byte(s, s.gzhead.time & 255);
			put_byte(s, s.gzhead.time >> 8 & 255);
			put_byte(s, s.gzhead.time >> 16 & 255);
			put_byte(s, s.gzhead.time >> 24 & 255);
			put_byte(s, s.level === 9 ? 2 : s.strategy >= Z_HUFFMAN_ONLY || s.level < 2 ? 4 : 0);
			put_byte(s, s.gzhead.os & 255);
			if (s.gzhead.extra && s.gzhead.extra.length) {
				put_byte(s, s.gzhead.extra.length & 255);
				put_byte(s, s.gzhead.extra.length >> 8 & 255);
			}
			if (s.gzhead.hcrc) strm.adler = crc32_1(strm.adler, s.pending_buf, s.pending, 0);
			s.gzindex = 0;
			s.status = EXTRA_STATE;
		}
	}
	if (s.status === EXTRA_STATE) {
		if (s.gzhead.extra) {
			let beg = s.pending;
			let left = (s.gzhead.extra.length & 65535) - s.gzindex;
			while (s.pending + left > s.pending_buf_size) {
				let copy = s.pending_buf_size - s.pending;
				s.pending_buf.set(s.gzhead.extra.subarray(s.gzindex, s.gzindex + copy), s.pending);
				s.pending = s.pending_buf_size;
				if (s.gzhead.hcrc && s.pending > beg) strm.adler = crc32_1(strm.adler, s.pending_buf, s.pending - beg, beg);
				s.gzindex += copy;
				flush_pending(strm);
				if (s.pending !== 0) {
					s.last_flush = -1;
					return Z_OK$3;
				}
				beg = 0;
				left -= copy;
			}
			let gzhead_extra = new Uint8Array(s.gzhead.extra);
			s.pending_buf.set(gzhead_extra.subarray(s.gzindex, s.gzindex + left), s.pending);
			s.pending += left;
			if (s.gzhead.hcrc && s.pending > beg) strm.adler = crc32_1(strm.adler, s.pending_buf, s.pending - beg, beg);
			s.gzindex = 0;
		}
		s.status = NAME_STATE;
	}
	if (s.status === NAME_STATE) {
		if (s.gzhead.name) {
			let beg = s.pending;
			let val;
			do {
				if (s.pending === s.pending_buf_size) {
					if (s.gzhead.hcrc && s.pending > beg) strm.adler = crc32_1(strm.adler, s.pending_buf, s.pending - beg, beg);
					flush_pending(strm);
					if (s.pending !== 0) {
						s.last_flush = -1;
						return Z_OK$3;
					}
					beg = 0;
				}
				if (s.gzindex < s.gzhead.name.length) val = s.gzhead.name.charCodeAt(s.gzindex++) & 255;
				else val = 0;
				put_byte(s, val);
			} while (val !== 0);
			if (s.gzhead.hcrc && s.pending > beg) strm.adler = crc32_1(strm.adler, s.pending_buf, s.pending - beg, beg);
			s.gzindex = 0;
		}
		s.status = COMMENT_STATE;
	}
	if (s.status === COMMENT_STATE) {
		if (s.gzhead.comment) {
			let beg = s.pending;
			let val;
			do {
				if (s.pending === s.pending_buf_size) {
					if (s.gzhead.hcrc && s.pending > beg) strm.adler = crc32_1(strm.adler, s.pending_buf, s.pending - beg, beg);
					flush_pending(strm);
					if (s.pending !== 0) {
						s.last_flush = -1;
						return Z_OK$3;
					}
					beg = 0;
				}
				if (s.gzindex < s.gzhead.comment.length) val = s.gzhead.comment.charCodeAt(s.gzindex++) & 255;
				else val = 0;
				put_byte(s, val);
			} while (val !== 0);
			if (s.gzhead.hcrc && s.pending > beg) strm.adler = crc32_1(strm.adler, s.pending_buf, s.pending - beg, beg);
		}
		s.status = HCRC_STATE;
	}
	if (s.status === HCRC_STATE) {
		if (s.gzhead.hcrc) {
			if (s.pending + 2 > s.pending_buf_size) {
				flush_pending(strm);
				if (s.pending !== 0) {
					s.last_flush = -1;
					return Z_OK$3;
				}
			}
			put_byte(s, strm.adler & 255);
			put_byte(s, strm.adler >> 8 & 255);
			strm.adler = 0;
		}
		s.status = BUSY_STATE;
		flush_pending(strm);
		if (s.pending !== 0) {
			s.last_flush = -1;
			return Z_OK$3;
		}
	}
	if (strm.avail_in !== 0 || s.lookahead !== 0 || flush !== Z_NO_FLUSH$2 && s.status !== FINISH_STATE) {
		let bstate = s.level === 0 ? deflate_stored(s, flush) : s.strategy === Z_HUFFMAN_ONLY ? deflate_huff(s, flush) : s.strategy === Z_RLE ? deflate_rle(s, flush) : configuration_table[s.level].func(s, flush);
		if (bstate === BS_FINISH_STARTED || bstate === BS_FINISH_DONE) s.status = FINISH_STATE;
		if (bstate === BS_NEED_MORE || bstate === BS_FINISH_STARTED) {
			if (strm.avail_out === 0) s.last_flush = -1;
			return Z_OK$3;
		}
		if (bstate === BS_BLOCK_DONE) {
			if (flush === Z_PARTIAL_FLUSH) _tr_align(s);
			else if (flush !== Z_BLOCK$1) {
				_tr_stored_block(s, 0, 0, false);
				if (flush === Z_FULL_FLUSH$1) {
					/*** CLEAR_HASH(s); ***/ zero(s.head);
					if (s.lookahead === 0) {
						s.strstart = 0;
						s.block_start = 0;
						s.insert = 0;
					}
				}
			}
			flush_pending(strm);
			if (strm.avail_out === 0) {
				s.last_flush = -1;
				return Z_OK$3;
			}
		}
	}
	if (flush !== Z_FINISH$3) return Z_OK$3;
	if (s.wrap <= 0) return Z_STREAM_END$3;
	if (s.wrap === 2) {
		put_byte(s, strm.adler & 255);
		put_byte(s, strm.adler >> 8 & 255);
		put_byte(s, strm.adler >> 16 & 255);
		put_byte(s, strm.adler >> 24 & 255);
		put_byte(s, strm.total_in & 255);
		put_byte(s, strm.total_in >> 8 & 255);
		put_byte(s, strm.total_in >> 16 & 255);
		put_byte(s, strm.total_in >> 24 & 255);
	} else {
		putShortMSB(s, strm.adler >>> 16);
		putShortMSB(s, strm.adler & 65535);
	}
	flush_pending(strm);
	if (s.wrap > 0) s.wrap = -s.wrap;
	return s.pending !== 0 ? Z_OK$3 : Z_STREAM_END$3;
};
const deflateEnd = (strm) => {
	if (deflateStateCheck(strm)) return Z_STREAM_ERROR$2;
	const status = strm.state.status;
	strm.state = null;
	return status === BUSY_STATE ? err(strm, Z_DATA_ERROR$2) : Z_OK$3;
};
const deflateSetDictionary = (strm, dictionary) => {
	let dictLength = dictionary.length;
	if (deflateStateCheck(strm)) return Z_STREAM_ERROR$2;
	const s = strm.state;
	const wrap = s.wrap;
	if (wrap === 2 || wrap === 1 && s.status !== INIT_STATE || s.lookahead) return Z_STREAM_ERROR$2;
	if (wrap === 1) strm.adler = adler32_1(strm.adler, dictionary, dictLength, 0);
	s.wrap = 0;
	if (dictLength >= s.w_size) {
		if (wrap === 0) {
			/*** CLEAR_HASH(s); ***/
			zero(s.head);
			s.strstart = 0;
			s.block_start = 0;
			s.insert = 0;
		}
		let tmpDict = new Uint8Array(s.w_size);
		tmpDict.set(dictionary.subarray(dictLength - s.w_size, dictLength), 0);
		dictionary = tmpDict;
		dictLength = s.w_size;
	}
	const avail = strm.avail_in;
	const next = strm.next_in;
	const input = strm.input;
	strm.avail_in = dictLength;
	strm.next_in = 0;
	strm.input = dictionary;
	fill_window(s);
	while (s.lookahead >= MIN_MATCH) {
		let str = s.strstart;
		let n = s.lookahead - (MIN_MATCH - 1);
		do {
			s.ins_h = HASH(s, s.ins_h, s.window[str + MIN_MATCH - 1]);
			s.prev[str & s.w_mask] = s.head[s.ins_h];
			s.head[s.ins_h] = str;
			str++;
		} while (--n);
		s.strstart = str;
		s.lookahead = MIN_MATCH - 1;
		fill_window(s);
	}
	s.strstart += s.lookahead;
	s.block_start = s.strstart;
	s.insert = s.lookahead;
	s.lookahead = 0;
	s.match_length = s.prev_length = MIN_MATCH - 1;
	s.match_available = 0;
	strm.next_in = next;
	strm.input = input;
	strm.avail_in = avail;
	s.wrap = wrap;
	return Z_OK$3;
};
var deflate_1$2 = {
	deflateInit,
	deflateInit2,
	deflateReset,
	deflateResetKeep,
	deflateSetHeader,
	deflate: deflate$2,
	deflateEnd,
	deflateSetDictionary,
	deflateInfo: "pako deflate (from Nodeca project)"
};
const _has = (obj, key) => {
	return Object.prototype.hasOwnProperty.call(obj, key);
};
var assign = function(obj) {
	const sources = Array.prototype.slice.call(arguments, 1);
	while (sources.length) {
		const source = sources.shift();
		if (!source) continue;
		if (typeof source !== "object") throw new TypeError(source + "must be non-object");
		for (const p in source) if (_has(source, p)) obj[p] = source[p];
	}
	return obj;
};
var flattenChunks = (chunks) => {
	let len = 0;
	for (let i = 0, l = chunks.length; i < l; i++) len += chunks[i].length;
	const result = new Uint8Array(len);
	for (let i = 0, pos = 0, l = chunks.length; i < l; i++) {
		let chunk = chunks[i];
		result.set(chunk, pos);
		pos += chunk.length;
	}
	return result;
};
var common = {
	assign,
	flattenChunks
};
let STR_APPLY_UIA_OK = true;
try {
	String.fromCharCode.apply(null, new Uint8Array(1));
} catch (__) {
	STR_APPLY_UIA_OK = false;
}
const _utf8len = new Uint8Array(256);
for (let q = 0; q < 256; q++) _utf8len[q] = q >= 252 ? 6 : q >= 248 ? 5 : q >= 240 ? 4 : q >= 224 ? 3 : q >= 192 ? 2 : 1;
_utf8len[254] = _utf8len[254] = 1;
var string2buf = (str) => {
	if (typeof TextEncoder === "function" && TextEncoder.prototype.encode) return new TextEncoder().encode(str);
	let buf, c, c2, m_pos, i, str_len = str.length, buf_len = 0;
	for (m_pos = 0; m_pos < str_len; m_pos++) {
		c = str.charCodeAt(m_pos);
		if ((c & 64512) === 55296 && m_pos + 1 < str_len) {
			c2 = str.charCodeAt(m_pos + 1);
			if ((c2 & 64512) === 56320) {
				c = 65536 + (c - 55296 << 10) + (c2 - 56320);
				m_pos++;
			}
		}
		buf_len += c < 128 ? 1 : c < 2048 ? 2 : c < 65536 ? 3 : 4;
	}
	buf = new Uint8Array(buf_len);
	for (i = 0, m_pos = 0; i < buf_len; m_pos++) {
		c = str.charCodeAt(m_pos);
		if ((c & 64512) === 55296 && m_pos + 1 < str_len) {
			c2 = str.charCodeAt(m_pos + 1);
			if ((c2 & 64512) === 56320) {
				c = 65536 + (c - 55296 << 10) + (c2 - 56320);
				m_pos++;
			}
		}
		if (c < 128) buf[i++] = c;
		else if (c < 2048) {
			buf[i++] = 192 | c >>> 6;
			buf[i++] = 128 | c & 63;
		} else if (c < 65536) {
			buf[i++] = 224 | c >>> 12;
			buf[i++] = 128 | c >>> 6 & 63;
			buf[i++] = 128 | c & 63;
		} else {
			buf[i++] = 240 | c >>> 18;
			buf[i++] = 128 | c >>> 12 & 63;
			buf[i++] = 128 | c >>> 6 & 63;
			buf[i++] = 128 | c & 63;
		}
	}
	return buf;
};
const buf2binstring = (buf, len) => {
	if (len < 65534) {
		if (buf.subarray && STR_APPLY_UIA_OK) return String.fromCharCode.apply(null, buf.length === len ? buf : buf.subarray(0, len));
	}
	let result = "";
	for (let i = 0; i < len; i++) result += String.fromCharCode(buf[i]);
	return result;
};
var buf2string = (buf, max) => {
	const len = max || buf.length;
	if (typeof TextDecoder === "function" && TextDecoder.prototype.decode) return new TextDecoder().decode(buf.subarray(0, max));
	let i, out;
	const utf16buf = new Array(len * 2);
	for (out = 0, i = 0; i < len;) {
		let c = buf[i++];
		if (c < 128) {
			utf16buf[out++] = c;
			continue;
		}
		let c_len = _utf8len[c];
		if (c_len > 4) {
			utf16buf[out++] = 65533;
			i += c_len - 1;
			continue;
		}
		c &= c_len === 2 ? 31 : c_len === 3 ? 15 : 7;
		while (c_len > 1 && i < len) {
			c = c << 6 | buf[i++] & 63;
			c_len--;
		}
		if (c_len > 1) {
			utf16buf[out++] = 65533;
			continue;
		}
		if (c < 65536) utf16buf[out++] = c;
		else {
			c -= 65536;
			utf16buf[out++] = 55296 | c >> 10 & 1023;
			utf16buf[out++] = 56320 | c & 1023;
		}
	}
	return buf2binstring(utf16buf, out);
};
var utf8border = (buf, max) => {
	max = max || buf.length;
	if (max > buf.length) max = buf.length;
	let pos = max - 1;
	while (pos >= 0 && (buf[pos] & 192) === 128) pos--;
	if (pos < 0) return max;
	if (pos === 0) return max;
	return pos + _utf8len[buf[pos]] > max ? pos : max;
};
var strings = {
	string2buf,
	buf2string,
	utf8border
};
function ZStream() {
	this.input = null;
	this.next_in = 0;
	this.avail_in = 0;
	this.total_in = 0;
	this.output = null;
	this.next_out = 0;
	this.avail_out = 0;
	this.total_out = 0;
	this.msg = "";
	this.state = null;
	this.data_type = 2;
	this.adler = 0;
}
var zstream = ZStream;
const toString$1 = Object.prototype.toString;
const { Z_NO_FLUSH: Z_NO_FLUSH$1, Z_SYNC_FLUSH, Z_FULL_FLUSH, Z_FINISH: Z_FINISH$2, Z_OK: Z_OK$2, Z_STREAM_END: Z_STREAM_END$2, Z_DEFAULT_COMPRESSION, Z_DEFAULT_STRATEGY, Z_DEFLATED: Z_DEFLATED$1 } = constants$2;
/**
* class Deflate
*
* Generic JS-style wrapper for zlib calls. If you don't need
* streaming behaviour - use more simple functions: [[deflate]],
* [[deflateRaw]] and [[gzip]].
**/
/**
* Deflate.result -> Uint8Array
*
* Compressed result, generated by default [[Deflate#onData]]
* and [[Deflate#onEnd]] handlers. Filled after you push last chunk
* (call [[Deflate#push]] with `Z_FINISH` / `true` param).
**/
/**
* Deflate.err -> Number
*
* Error code after deflate finished. 0 (Z_OK) on success.
* You will not need it in real life, because deflate errors
* are possible only on wrong options or bad `onData` / `onEnd`
* custom handlers.
**/
/**
* Deflate.msg -> String
*
* Error message, if [[Deflate.err]] != 0
**/
/**
* new Deflate(options)
* - options (Object): zlib deflate options.
*
* Creates new deflator instance with specified params. Throws exception
* on bad params. Supported options:
*
* - `level`
* - `windowBits`
* - `memLevel`
* - `strategy`
* - `dictionary`
*
* [http://zlib.net/manual.html#Advanced](http://zlib.net/manual.html#Advanced)
* for more information on these.
*
* Additional options, for internal needs:
*
* - `chunkSize` - size of generated data chunks (16K by default)
* - `raw` (Boolean) - do raw deflate
* - `gzip` (Boolean) - create gzip wrapper
* - `header` (Object) - custom header for gzip
*   - `text` (Boolean) - true if compressed data believed to be text
*   - `time` (Number) - modification time, unix timestamp
*   - `os` (Number) - operation system code
*   - `extra` (Array) - array of bytes with extra data (max 65536)
*   - `name` (String) - file name (binary string)
*   - `comment` (String) - comment (binary string)
*   - `hcrc` (Boolean) - true if header crc should be added
*
* ##### Example:
*
* ```javascript
* const pako = require('pako')
*   , chunk1 = new Uint8Array([1,2,3,4,5,6,7,8,9])
*   , chunk2 = new Uint8Array([10,11,12,13,14,15,16,17,18,19]);
*
* const deflate = new pako.Deflate({ level: 3});
*
* deflate.push(chunk1, false);
* deflate.push(chunk2, true);  // true -> last chunk
*
* if (deflate.err) { throw new Error(deflate.err); }
*
* console.log(deflate.result);
* ```
**/
function Deflate$1(options) {
	this.options = common.assign({
		level: Z_DEFAULT_COMPRESSION,
		method: Z_DEFLATED$1,
		chunkSize: 16384,
		windowBits: 15,
		memLevel: 8,
		strategy: Z_DEFAULT_STRATEGY
	}, options || {});
	let opt = this.options;
	if (opt.raw && opt.windowBits > 0) opt.windowBits = -opt.windowBits;
	else if (opt.gzip && opt.windowBits > 0 && opt.windowBits < 16) opt.windowBits += 16;
	this.err = 0;
	this.msg = "";
	this.ended = false;
	this.chunks = [];
	this.strm = new zstream();
	this.strm.avail_out = 0;
	let status = deflate_1$2.deflateInit2(this.strm, opt.level, opt.method, opt.windowBits, opt.memLevel, opt.strategy);
	if (status !== Z_OK$2) throw new Error(messages[status]);
	if (opt.header) deflate_1$2.deflateSetHeader(this.strm, opt.header);
	if (opt.dictionary) {
		let dict;
		if (typeof opt.dictionary === "string") dict = strings.string2buf(opt.dictionary);
		else if (toString$1.call(opt.dictionary) === "[object ArrayBuffer]") dict = new Uint8Array(opt.dictionary);
		else dict = opt.dictionary;
		status = deflate_1$2.deflateSetDictionary(this.strm, dict);
		if (status !== Z_OK$2) throw new Error(messages[status]);
		this._dict_set = true;
	}
}
/**
* Deflate#push(data[, flush_mode]) -> Boolean
* - data (Uint8Array|ArrayBuffer|String): input data. Strings will be
*   converted to utf8 byte sequence.
* - flush_mode (Number|Boolean): 0..6 for corresponding Z_NO_FLUSH..Z_TREE modes.
*   See constants. Skipped or `false` means Z_NO_FLUSH, `true` means Z_FINISH.
*
* Sends input data to deflate pipe, generating [[Deflate#onData]] calls with
* new compressed chunks. Returns `true` on success. The last data block must
* have `flush_mode` Z_FINISH (or `true`). That will flush internal pending
* buffers and call [[Deflate#onEnd]].
*
* On fail call [[Deflate#onEnd]] with error code and return false.
*
* ##### Example
*
* ```javascript
* push(chunk, false); // push one of data chunks
* ...
* push(chunk, true);  // push last chunk
* ```
**/
Deflate$1.prototype.push = function(data, flush_mode) {
	const strm = this.strm;
	const chunkSize = this.options.chunkSize;
	let status, _flush_mode;
	if (this.ended) return false;
	if (flush_mode === ~~flush_mode) _flush_mode = flush_mode;
	else _flush_mode = flush_mode === true ? Z_FINISH$2 : Z_NO_FLUSH$1;
	if (typeof data === "string") strm.input = strings.string2buf(data);
	else if (toString$1.call(data) === "[object ArrayBuffer]") strm.input = new Uint8Array(data);
	else strm.input = data;
	strm.next_in = 0;
	strm.avail_in = strm.input.length;
	for (;;) {
		if (strm.avail_out === 0) {
			strm.output = new Uint8Array(chunkSize);
			strm.next_out = 0;
			strm.avail_out = chunkSize;
		}
		if ((_flush_mode === Z_SYNC_FLUSH || _flush_mode === Z_FULL_FLUSH) && strm.avail_out <= 6) {
			this.onData(strm.output.subarray(0, strm.next_out));
			strm.avail_out = 0;
			continue;
		}
		status = deflate_1$2.deflate(strm, _flush_mode);
		if (status === Z_STREAM_END$2) {
			if (strm.next_out > 0) this.onData(strm.output.subarray(0, strm.next_out));
			status = deflate_1$2.deflateEnd(this.strm);
			this.onEnd(status);
			this.ended = true;
			return status === Z_OK$2;
		}
		if (strm.avail_out === 0) {
			this.onData(strm.output);
			continue;
		}
		if (_flush_mode > 0 && strm.next_out > 0) {
			this.onData(strm.output.subarray(0, strm.next_out));
			strm.avail_out = 0;
			continue;
		}
		if (strm.avail_in === 0) break;
	}
	return true;
};
/**
* Deflate#onData(chunk) -> Void
* - chunk (Uint8Array): output data.
*
* By default, stores data blocks in `chunks[]` property and glue
* those in `onEnd`. Override this handler, if you need another behaviour.
**/
Deflate$1.prototype.onData = function(chunk) {
	this.chunks.push(chunk);
};
/**
* Deflate#onEnd(status) -> Void
* - status (Number): deflate status. 0 (Z_OK) on success,
*   other if not.
*
* Called once after you tell deflate that the input stream is
* complete (Z_FINISH). By default - join collected chunks,
* free memory and fill `results` / `err` properties.
**/
Deflate$1.prototype.onEnd = function(status) {
	if (status === Z_OK$2) this.result = common.flattenChunks(this.chunks);
	this.chunks = [];
	this.err = status;
	this.msg = this.strm.msg;
};
/**
* deflate(data[, options]) -> Uint8Array
* - data (Uint8Array|ArrayBuffer|String): input data to compress.
* - options (Object): zlib deflate options.
*
* Compress `data` with deflate algorithm and `options`.
*
* Supported options are:
*
* - level
* - windowBits
* - memLevel
* - strategy
* - dictionary
*
* [http://zlib.net/manual.html#Advanced](http://zlib.net/manual.html#Advanced)
* for more information on these.
*
* Sugar (options):
*
* - `raw` (Boolean) - say that we work with raw stream, if you don't wish to specify
*   negative windowBits implicitly.
*
* ##### Example:
*
* ```javascript
* const pako = require('pako')
* const data = new Uint8Array([1,2,3,4,5,6,7,8,9]);
*
* console.log(pako.deflate(data));
* ```
**/
function deflate$1(input, options) {
	const deflator = new Deflate$1(options);
	deflator.push(input, true);
	if (deflator.err) throw deflator.msg || messages[deflator.err];
	return deflator.result;
}
/**
* deflateRaw(data[, options]) -> Uint8Array
* - data (Uint8Array|ArrayBuffer|String): input data to compress.
* - options (Object): zlib deflate options.
*
* The same as [[deflate]], but creates raw data, without wrapper
* (header and adler32 crc).
**/
function deflateRaw$1(input, options) {
	options = options || {};
	options.raw = true;
	return deflate$1(input, options);
}
/**
* gzip(data[, options]) -> Uint8Array
* - data (Uint8Array|ArrayBuffer|String): input data to compress.
* - options (Object): zlib deflate options.
*
* The same as [[deflate]], but create gzip wrapper instead of
* deflate one.
**/
function gzip$1(input, options) {
	options = options || {};
	options.gzip = true;
	return deflate$1(input, options);
}
var deflate_1$1 = {
	Deflate: Deflate$1,
	deflate: deflate$1,
	deflateRaw: deflateRaw$1,
	gzip: gzip$1,
	constants: constants$2
};
const BAD$1 = 16209;
const TYPE$1 = 16191;
var inffast = function inflate_fast(strm, start) {
	let _in;
	let last;
	let _out;
	let beg;
	let end;
	let dmax;
	let wsize;
	let whave;
	let wnext;
	let s_window;
	let hold;
	let bits;
	let lcode;
	let dcode;
	let lmask;
	let dmask;
	let here;
	let op;
	let len;
	let dist;
	let from;
	let from_source;
	let input, output;
	const state = strm.state;
	_in = strm.next_in;
	input = strm.input;
	last = _in + (strm.avail_in - 5);
	_out = strm.next_out;
	output = strm.output;
	beg = _out - (start - strm.avail_out);
	end = _out + (strm.avail_out - 257);
	dmax = state.dmax;
	wsize = state.wsize;
	whave = state.whave;
	wnext = state.wnext;
	s_window = state.window;
	hold = state.hold;
	bits = state.bits;
	lcode = state.lencode;
	dcode = state.distcode;
	lmask = (1 << state.lenbits) - 1;
	dmask = (1 << state.distbits) - 1;
	top: do {
		if (bits < 15) {
			hold += input[_in++] << bits;
			bits += 8;
			hold += input[_in++] << bits;
			bits += 8;
		}
		here = lcode[hold & lmask];
		dolen: for (;;) {
			op = here >>> 24;
			hold >>>= op;
			bits -= op;
			op = here >>> 16 & 255;
			if (op === 0) output[_out++] = here & 65535;
			else if (op & 16) {
				len = here & 65535;
				op &= 15;
				if (op) {
					if (bits < op) {
						hold += input[_in++] << bits;
						bits += 8;
					}
					len += hold & (1 << op) - 1;
					hold >>>= op;
					bits -= op;
				}
				if (bits < 15) {
					hold += input[_in++] << bits;
					bits += 8;
					hold += input[_in++] << bits;
					bits += 8;
				}
				here = dcode[hold & dmask];
				dodist: for (;;) {
					op = here >>> 24;
					hold >>>= op;
					bits -= op;
					op = here >>> 16 & 255;
					if (op & 16) {
						dist = here & 65535;
						op &= 15;
						if (bits < op) {
							hold += input[_in++] << bits;
							bits += 8;
							if (bits < op) {
								hold += input[_in++] << bits;
								bits += 8;
							}
						}
						dist += hold & (1 << op) - 1;
						if (dist > dmax) {
							strm.msg = "invalid distance too far back";
							state.mode = BAD$1;
							break top;
						}
						hold >>>= op;
						bits -= op;
						op = _out - beg;
						if (dist > op) {
							op = dist - op;
							if (op > whave) {
								if (state.sane) {
									strm.msg = "invalid distance too far back";
									state.mode = BAD$1;
									break top;
								}
							}
							from = 0;
							from_source = s_window;
							if (wnext === 0) {
								from += wsize - op;
								if (op < len) {
									len -= op;
									do
										output[_out++] = s_window[from++];
									while (--op);
									from = _out - dist;
									from_source = output;
								}
							} else if (wnext < op) {
								from += wsize + wnext - op;
								op -= wnext;
								if (op < len) {
									len -= op;
									do
										output[_out++] = s_window[from++];
									while (--op);
									from = 0;
									if (wnext < len) {
										op = wnext;
										len -= op;
										do
											output[_out++] = s_window[from++];
										while (--op);
										from = _out - dist;
										from_source = output;
									}
								}
							} else {
								from += wnext - op;
								if (op < len) {
									len -= op;
									do
										output[_out++] = s_window[from++];
									while (--op);
									from = _out - dist;
									from_source = output;
								}
							}
							while (len > 2) {
								output[_out++] = from_source[from++];
								output[_out++] = from_source[from++];
								output[_out++] = from_source[from++];
								len -= 3;
							}
							if (len) {
								output[_out++] = from_source[from++];
								if (len > 1) output[_out++] = from_source[from++];
							}
						} else {
							from = _out - dist;
							do {
								output[_out++] = output[from++];
								output[_out++] = output[from++];
								output[_out++] = output[from++];
								len -= 3;
							} while (len > 2);
							if (len) {
								output[_out++] = output[from++];
								if (len > 1) output[_out++] = output[from++];
							}
						}
					} else if ((op & 64) === 0) {
						here = dcode[(here & 65535) + (hold & (1 << op) - 1)];
						continue dodist;
					} else {
						strm.msg = "invalid distance code";
						state.mode = BAD$1;
						break top;
					}
					break;
				}
			} else if ((op & 64) === 0) {
				here = lcode[(here & 65535) + (hold & (1 << op) - 1)];
				continue dolen;
			} else if (op & 32) {
				state.mode = TYPE$1;
				break top;
			} else {
				strm.msg = "invalid literal/length code";
				state.mode = BAD$1;
				break top;
			}
			break;
		}
	} while (_in < last && _out < end);
	len = bits >> 3;
	_in -= len;
	bits -= len << 3;
	hold &= (1 << bits) - 1;
	strm.next_in = _in;
	strm.next_out = _out;
	strm.avail_in = _in < last ? 5 + (last - _in) : 5 - (_in - last);
	strm.avail_out = _out < end ? 257 + (end - _out) : 257 - (_out - end);
	state.hold = hold;
	state.bits = bits;
};
const MAXBITS = 15;
const ENOUGH_LENS$1 = 852;
const ENOUGH_DISTS$1 = 592;
const CODES$1 = 0;
const LENS$1 = 1;
const DISTS$1 = 2;
const lbase = new Uint16Array([
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
	0,
	0
]);
const lext = new Uint8Array([
	16,
	16,
	16,
	16,
	16,
	16,
	16,
	16,
	17,
	17,
	17,
	17,
	18,
	18,
	18,
	18,
	19,
	19,
	19,
	19,
	20,
	20,
	20,
	20,
	21,
	21,
	21,
	21,
	16,
	72,
	78
]);
const dbase = new Uint16Array([
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
	0,
	0
]);
const dext = new Uint8Array([
	16,
	16,
	16,
	16,
	17,
	17,
	18,
	18,
	19,
	19,
	20,
	20,
	21,
	21,
	22,
	22,
	23,
	23,
	24,
	24,
	25,
	25,
	26,
	26,
	27,
	27,
	28,
	28,
	29,
	29,
	64,
	64
]);
const inflate_table = (type, lens, lens_index, codes, table, table_index, work, opts) => {
	const bits = opts.bits;
	let len = 0;
	let sym = 0;
	let min = 0, max = 0;
	let root = 0;
	let curr = 0;
	let drop = 0;
	let left = 0;
	let used = 0;
	let huff = 0;
	let incr;
	let fill;
	let low;
	let mask;
	let next;
	let base = null;
	let match;
	const count = new Uint16Array(MAXBITS + 1);
	const offs = new Uint16Array(MAXBITS + 1);
	let extra = null;
	let here_bits, here_op, here_val;
	for (len = 0; len <= MAXBITS; len++) count[len] = 0;
	for (sym = 0; sym < codes; sym++) count[lens[lens_index + sym]]++;
	root = bits;
	for (max = MAXBITS; max >= 1; max--) if (count[max] !== 0) break;
	if (root > max) root = max;
	if (max === 0) {
		table[table_index++] = 20971520;
		table[table_index++] = 20971520;
		opts.bits = 1;
		return 0;
	}
	for (min = 1; min < max; min++) if (count[min] !== 0) break;
	if (root < min) root = min;
	left = 1;
	for (len = 1; len <= MAXBITS; len++) {
		left <<= 1;
		left -= count[len];
		if (left < 0) return -1;
	}
	if (left > 0 && (type === CODES$1 || max !== 1)) return -1;
	offs[1] = 0;
	for (len = 1; len < MAXBITS; len++) offs[len + 1] = offs[len] + count[len];
	for (sym = 0; sym < codes; sym++) if (lens[lens_index + sym] !== 0) work[offs[lens[lens_index + sym]]++] = sym;
	if (type === CODES$1) {
		base = extra = work;
		match = 20;
	} else if (type === LENS$1) {
		base = lbase;
		extra = lext;
		match = 257;
	} else {
		base = dbase;
		extra = dext;
		match = 0;
	}
	huff = 0;
	sym = 0;
	len = min;
	next = table_index;
	curr = root;
	drop = 0;
	low = -1;
	used = 1 << root;
	mask = used - 1;
	if (type === LENS$1 && used > ENOUGH_LENS$1 || type === DISTS$1 && used > ENOUGH_DISTS$1) return 1;
	for (;;) {
		here_bits = len - drop;
		if (work[sym] + 1 < match) {
			here_op = 0;
			here_val = work[sym];
		} else if (work[sym] >= match) {
			here_op = extra[work[sym] - match];
			here_val = base[work[sym] - match];
		} else {
			here_op = 96;
			here_val = 0;
		}
		incr = 1 << len - drop;
		fill = 1 << curr;
		min = fill;
		do {
			fill -= incr;
			table[next + (huff >> drop) + fill] = here_bits << 24 | here_op << 16 | here_val | 0;
		} while (fill !== 0);
		incr = 1 << len - 1;
		while (huff & incr) incr >>= 1;
		if (incr !== 0) {
			huff &= incr - 1;
			huff += incr;
		} else huff = 0;
		sym++;
		if (--count[len] === 0) {
			if (len === max) break;
			len = lens[lens_index + work[sym]];
		}
		if (len > root && (huff & mask) !== low) {
			if (drop === 0) drop = root;
			next += min;
			curr = len - drop;
			left = 1 << curr;
			while (curr + drop < max) {
				left -= count[curr + drop];
				if (left <= 0) break;
				curr++;
				left <<= 1;
			}
			used += 1 << curr;
			if (type === LENS$1 && used > ENOUGH_LENS$1 || type === DISTS$1 && used > ENOUGH_DISTS$1) return 1;
			low = huff & mask;
			table[low] = root << 24 | curr << 16 | next - table_index | 0;
		}
	}
	if (huff !== 0) table[next + huff] = len - drop << 24 | 4194304;
	opts.bits = root;
	return 0;
};
var inftrees = inflate_table;
const CODES = 0;
const LENS = 1;
const DISTS = 2;
const { Z_FINISH: Z_FINISH$1, Z_BLOCK, Z_TREES, Z_OK: Z_OK$1, Z_STREAM_END: Z_STREAM_END$1, Z_NEED_DICT: Z_NEED_DICT$1, Z_STREAM_ERROR: Z_STREAM_ERROR$1, Z_DATA_ERROR: Z_DATA_ERROR$1, Z_MEM_ERROR: Z_MEM_ERROR$1, Z_BUF_ERROR, Z_DEFLATED } = constants$2;
const HEAD = 16180;
const FLAGS = 16181;
const TIME = 16182;
const OS = 16183;
const EXLEN = 16184;
const EXTRA = 16185;
const NAME = 16186;
const COMMENT = 16187;
const HCRC = 16188;
const DICTID = 16189;
const DICT = 16190;
const TYPE = 16191;
const TYPEDO = 16192;
const STORED = 16193;
const COPY_ = 16194;
const COPY = 16195;
const TABLE = 16196;
const LENLENS = 16197;
const CODELENS = 16198;
const LEN_ = 16199;
const LEN = 16200;
const LENEXT = 16201;
const DIST = 16202;
const DISTEXT = 16203;
const MATCH = 16204;
const LIT = 16205;
const CHECK = 16206;
const LENGTH = 16207;
const DONE = 16208;
const BAD = 16209;
const MEM = 16210;
const SYNC = 16211;
const ENOUGH_LENS = 852;
const ENOUGH_DISTS = 592;
const DEF_WBITS = 15;
const zswap32 = (q) => {
	return (q >>> 24 & 255) + (q >>> 8 & 65280) + ((q & 65280) << 8) + ((q & 255) << 24);
};
function InflateState() {
	this.strm = null;
	this.mode = 0;
	this.last = false;
	this.wrap = 0;
	this.havedict = false;
	this.flags = 0;
	this.dmax = 0;
	this.check = 0;
	this.total = 0;
	this.head = null;
	this.wbits = 0;
	this.wsize = 0;
	this.whave = 0;
	this.wnext = 0;
	this.window = null;
	this.hold = 0;
	this.bits = 0;
	this.length = 0;
	this.offset = 0;
	this.extra = 0;
	this.lencode = null;
	this.distcode = null;
	this.lenbits = 0;
	this.distbits = 0;
	this.ncode = 0;
	this.nlen = 0;
	this.ndist = 0;
	this.have = 0;
	this.next = null;
	this.lens = new Uint16Array(320);
	this.work = new Uint16Array(288);
	this.lendyn = null;
	this.distdyn = null;
	this.sane = 0;
	this.back = 0;
	this.was = 0;
}
const inflateStateCheck = (strm) => {
	if (!strm) return 1;
	const state = strm.state;
	if (!state || state.strm !== strm || state.mode < HEAD || state.mode > SYNC) return 1;
	return 0;
};
const inflateResetKeep = (strm) => {
	if (inflateStateCheck(strm)) return Z_STREAM_ERROR$1;
	const state = strm.state;
	strm.total_in = strm.total_out = state.total = 0;
	strm.msg = "";
	if (state.wrap) strm.adler = state.wrap & 1;
	state.mode = HEAD;
	state.last = 0;
	state.havedict = 0;
	state.flags = -1;
	state.dmax = 32768;
	state.head = null;
	state.hold = 0;
	state.bits = 0;
	state.lencode = state.lendyn = new Int32Array(ENOUGH_LENS);
	state.distcode = state.distdyn = new Int32Array(ENOUGH_DISTS);
	state.sane = 1;
	state.back = -1;
	return Z_OK$1;
};
const inflateReset = (strm) => {
	if (inflateStateCheck(strm)) return Z_STREAM_ERROR$1;
	const state = strm.state;
	state.wsize = 0;
	state.whave = 0;
	state.wnext = 0;
	return inflateResetKeep(strm);
};
const inflateReset2 = (strm, windowBits) => {
	let wrap;
	if (inflateStateCheck(strm)) return Z_STREAM_ERROR$1;
	const state = strm.state;
	if (windowBits < 0) {
		wrap = 0;
		windowBits = -windowBits;
	} else {
		wrap = (windowBits >> 4) + 5;
		if (windowBits < 48) windowBits &= 15;
	}
	if (windowBits && (windowBits < 8 || windowBits > 15)) return Z_STREAM_ERROR$1;
	if (state.window !== null && state.wbits !== windowBits) state.window = null;
	state.wrap = wrap;
	state.wbits = windowBits;
	return inflateReset(strm);
};
const inflateInit2 = (strm, windowBits) => {
	if (!strm) return Z_STREAM_ERROR$1;
	const state = new InflateState();
	strm.state = state;
	state.strm = strm;
	state.window = null;
	state.mode = HEAD;
	const ret = inflateReset2(strm, windowBits);
	if (ret !== Z_OK$1) strm.state = null;
	return ret;
};
const inflateInit = (strm) => {
	return inflateInit2(strm, DEF_WBITS);
};
let virgin = true;
let lenfix, distfix;
const fixedtables = (state) => {
	if (virgin) {
		lenfix = new Int32Array(512);
		distfix = new Int32Array(32);
		let sym = 0;
		while (sym < 144) state.lens[sym++] = 8;
		while (sym < 256) state.lens[sym++] = 9;
		while (sym < 280) state.lens[sym++] = 7;
		while (sym < 288) state.lens[sym++] = 8;
		inftrees(LENS, state.lens, 0, 288, lenfix, 0, state.work, { bits: 9 });
		sym = 0;
		while (sym < 32) state.lens[sym++] = 5;
		inftrees(DISTS, state.lens, 0, 32, distfix, 0, state.work, { bits: 5 });
		virgin = false;
	}
	state.lencode = lenfix;
	state.lenbits = 9;
	state.distcode = distfix;
	state.distbits = 5;
};
const updatewindow = (strm, src, end, copy) => {
	let dist;
	const state = strm.state;
	if (state.window === null) {
		state.wsize = 1 << state.wbits;
		state.wnext = 0;
		state.whave = 0;
		state.window = new Uint8Array(state.wsize);
	}
	if (copy >= state.wsize) {
		state.window.set(src.subarray(end - state.wsize, end), 0);
		state.wnext = 0;
		state.whave = state.wsize;
	} else {
		dist = state.wsize - state.wnext;
		if (dist > copy) dist = copy;
		state.window.set(src.subarray(end - copy, end - copy + dist), state.wnext);
		copy -= dist;
		if (copy) {
			state.window.set(src.subarray(end - copy, end), 0);
			state.wnext = copy;
			state.whave = state.wsize;
		} else {
			state.wnext += dist;
			if (state.wnext === state.wsize) state.wnext = 0;
			if (state.whave < state.wsize) state.whave += dist;
		}
	}
	return 0;
};
const inflate$2 = (strm, flush) => {
	let state;
	let input, output;
	let next;
	let put;
	let have, left;
	let hold;
	let bits;
	let _in, _out;
	let copy;
	let from;
	let from_source;
	let here = 0;
	let here_bits, here_op, here_val;
	let last_bits, last_op, last_val;
	let len;
	let ret;
	const hbuf = new Uint8Array(4);
	let opts;
	let n;
	const order = new Uint8Array([
		16,
		17,
		18,
		0,
		8,
		7,
		9,
		6,
		10,
		5,
		11,
		4,
		12,
		3,
		13,
		2,
		14,
		1,
		15
	]);
	if (inflateStateCheck(strm) || !strm.output || !strm.input && strm.avail_in !== 0) return Z_STREAM_ERROR$1;
	state = strm.state;
	if (state.mode === TYPE) state.mode = TYPEDO;
	put = strm.next_out;
	output = strm.output;
	left = strm.avail_out;
	next = strm.next_in;
	input = strm.input;
	have = strm.avail_in;
	hold = state.hold;
	bits = state.bits;
	_in = have;
	_out = left;
	ret = Z_OK$1;
	inf_leave: for (;;) switch (state.mode) {
		case HEAD:
			if (state.wrap === 0) {
				state.mode = TYPEDO;
				break;
			}
			while (bits < 16) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			if (state.wrap & 2 && hold === 35615) {
				if (state.wbits === 0) state.wbits = 15;
				state.check = 0;
				hbuf[0] = hold & 255;
				hbuf[1] = hold >>> 8 & 255;
				state.check = crc32_1(state.check, hbuf, 2, 0);
				hold = 0;
				bits = 0;
				state.mode = FLAGS;
				break;
			}
			if (state.head) state.head.done = false;
			if (!(state.wrap & 1) || (((hold & 255) << 8) + (hold >> 8)) % 31) {
				strm.msg = "incorrect header check";
				state.mode = BAD;
				break;
			}
			if ((hold & 15) !== Z_DEFLATED) {
				strm.msg = "unknown compression method";
				state.mode = BAD;
				break;
			}
			hold >>>= 4;
			bits -= 4;
			len = (hold & 15) + 8;
			if (state.wbits === 0) state.wbits = len;
			if (len > 15 || len > state.wbits) {
				strm.msg = "invalid window size";
				state.mode = BAD;
				break;
			}
			state.dmax = 1 << state.wbits;
			state.flags = 0;
			strm.adler = state.check = 1;
			state.mode = hold & 512 ? DICTID : TYPE;
			hold = 0;
			bits = 0;
			break;
		case FLAGS:
			while (bits < 16) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			state.flags = hold;
			if ((state.flags & 255) !== Z_DEFLATED) {
				strm.msg = "unknown compression method";
				state.mode = BAD;
				break;
			}
			if (state.flags & 57344) {
				strm.msg = "unknown header flags set";
				state.mode = BAD;
				break;
			}
			if (state.head) state.head.text = hold >> 8 & 1;
			if (state.flags & 512 && state.wrap & 4) {
				hbuf[0] = hold & 255;
				hbuf[1] = hold >>> 8 & 255;
				state.check = crc32_1(state.check, hbuf, 2, 0);
			}
			hold = 0;
			bits = 0;
			state.mode = TIME;
		case TIME:
			while (bits < 32) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			if (state.head) state.head.time = hold;
			if (state.flags & 512 && state.wrap & 4) {
				hbuf[0] = hold & 255;
				hbuf[1] = hold >>> 8 & 255;
				hbuf[2] = hold >>> 16 & 255;
				hbuf[3] = hold >>> 24 & 255;
				state.check = crc32_1(state.check, hbuf, 4, 0);
			}
			hold = 0;
			bits = 0;
			state.mode = OS;
		case OS:
			while (bits < 16) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			if (state.head) {
				state.head.xflags = hold & 255;
				state.head.os = hold >> 8;
			}
			if (state.flags & 512 && state.wrap & 4) {
				hbuf[0] = hold & 255;
				hbuf[1] = hold >>> 8 & 255;
				state.check = crc32_1(state.check, hbuf, 2, 0);
			}
			hold = 0;
			bits = 0;
			state.mode = EXLEN;
		case EXLEN:
			if (state.flags & 1024) {
				while (bits < 16) {
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				state.length = hold;
				if (state.head) state.head.extra_len = hold;
				if (state.flags & 512 && state.wrap & 4) {
					hbuf[0] = hold & 255;
					hbuf[1] = hold >>> 8 & 255;
					state.check = crc32_1(state.check, hbuf, 2, 0);
				}
				hold = 0;
				bits = 0;
			} else if (state.head) state.head.extra = null;
			state.mode = EXTRA;
		case EXTRA:
			if (state.flags & 1024) {
				copy = state.length;
				if (copy > have) copy = have;
				if (copy) {
					if (state.head) {
						len = state.head.extra_len - state.length;
						if (!state.head.extra) state.head.extra = new Uint8Array(state.head.extra_len);
						state.head.extra.set(input.subarray(next, next + copy), len);
					}
					if (state.flags & 512 && state.wrap & 4) state.check = crc32_1(state.check, input, copy, next);
					have -= copy;
					next += copy;
					state.length -= copy;
				}
				if (state.length) break inf_leave;
			}
			state.length = 0;
			state.mode = NAME;
		case NAME:
			if (state.flags & 2048) {
				if (have === 0) break inf_leave;
				copy = 0;
				do {
					len = input[next + copy++];
					if (state.head && len && state.length < 65536) state.head.name += String.fromCharCode(len);
				} while (len && copy < have);
				if (state.flags & 512 && state.wrap & 4) state.check = crc32_1(state.check, input, copy, next);
				have -= copy;
				next += copy;
				if (len) break inf_leave;
			} else if (state.head) state.head.name = null;
			state.length = 0;
			state.mode = COMMENT;
		case COMMENT:
			if (state.flags & 4096) {
				if (have === 0) break inf_leave;
				copy = 0;
				do {
					len = input[next + copy++];
					if (state.head && len && state.length < 65536) state.head.comment += String.fromCharCode(len);
				} while (len && copy < have);
				if (state.flags & 512 && state.wrap & 4) state.check = crc32_1(state.check, input, copy, next);
				have -= copy;
				next += copy;
				if (len) break inf_leave;
			} else if (state.head) state.head.comment = null;
			state.mode = HCRC;
		case HCRC:
			if (state.flags & 512) {
				while (bits < 16) {
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				if (state.wrap & 4 && hold !== (state.check & 65535)) {
					strm.msg = "header crc mismatch";
					state.mode = BAD;
					break;
				}
				hold = 0;
				bits = 0;
			}
			if (state.head) {
				state.head.hcrc = state.flags >> 9 & 1;
				state.head.done = true;
			}
			strm.adler = state.check = 0;
			state.mode = TYPE;
			break;
		case DICTID:
			while (bits < 32) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			strm.adler = state.check = zswap32(hold);
			hold = 0;
			bits = 0;
			state.mode = DICT;
		case DICT:
			if (state.havedict === 0) {
				strm.next_out = put;
				strm.avail_out = left;
				strm.next_in = next;
				strm.avail_in = have;
				state.hold = hold;
				state.bits = bits;
				return Z_NEED_DICT$1;
			}
			strm.adler = state.check = 1;
			state.mode = TYPE;
		case TYPE: if (flush === Z_BLOCK || flush === Z_TREES) break inf_leave;
		case TYPEDO:
			if (state.last) {
				hold >>>= bits & 7;
				bits -= bits & 7;
				state.mode = CHECK;
				break;
			}
			while (bits < 3) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			state.last = hold & 1;
			hold >>>= 1;
			bits -= 1;
			switch (hold & 3) {
				case 0:
					state.mode = STORED;
					break;
				case 1:
					fixedtables(state);
					state.mode = LEN_;
					if (flush === Z_TREES) {
						hold >>>= 2;
						bits -= 2;
						break inf_leave;
					}
					break;
				case 2:
					state.mode = TABLE;
					break;
				case 3:
					strm.msg = "invalid block type";
					state.mode = BAD;
			}
			hold >>>= 2;
			bits -= 2;
			break;
		case STORED:
			hold >>>= bits & 7;
			bits -= bits & 7;
			while (bits < 32) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			if ((hold & 65535) !== (hold >>> 16 ^ 65535)) {
				strm.msg = "invalid stored block lengths";
				state.mode = BAD;
				break;
			}
			state.length = hold & 65535;
			hold = 0;
			bits = 0;
			state.mode = COPY_;
			if (flush === Z_TREES) break inf_leave;
		case COPY_: state.mode = COPY;
		case COPY:
			copy = state.length;
			if (copy) {
				if (copy > have) copy = have;
				if (copy > left) copy = left;
				if (copy === 0) break inf_leave;
				output.set(input.subarray(next, next + copy), put);
				have -= copy;
				next += copy;
				left -= copy;
				put += copy;
				state.length -= copy;
				break;
			}
			state.mode = TYPE;
			break;
		case TABLE:
			while (bits < 14) {
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			state.nlen = (hold & 31) + 257;
			hold >>>= 5;
			bits -= 5;
			state.ndist = (hold & 31) + 1;
			hold >>>= 5;
			bits -= 5;
			state.ncode = (hold & 15) + 4;
			hold >>>= 4;
			bits -= 4;
			if (state.nlen > 286 || state.ndist > 30) {
				strm.msg = "too many length or distance symbols";
				state.mode = BAD;
				break;
			}
			state.have = 0;
			state.mode = LENLENS;
		case LENLENS:
			while (state.have < state.ncode) {
				while (bits < 3) {
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				state.lens[order[state.have++]] = hold & 7;
				hold >>>= 3;
				bits -= 3;
			}
			while (state.have < 19) state.lens[order[state.have++]] = 0;
			state.lencode = state.lendyn;
			state.lenbits = 7;
			opts = { bits: state.lenbits };
			ret = inftrees(CODES, state.lens, 0, 19, state.lencode, 0, state.work, opts);
			state.lenbits = opts.bits;
			if (ret) {
				strm.msg = "invalid code lengths set";
				state.mode = BAD;
				break;
			}
			state.have = 0;
			state.mode = CODELENS;
		case CODELENS:
			while (state.have < state.nlen + state.ndist) {
				for (;;) {
					here = state.lencode[hold & (1 << state.lenbits) - 1];
					here_bits = here >>> 24;
					here_op = here >>> 16 & 255;
					here_val = here & 65535;
					if (here_bits <= bits) break;
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				if (here_val < 16) {
					hold >>>= here_bits;
					bits -= here_bits;
					state.lens[state.have++] = here_val;
				} else {
					if (here_val === 16) {
						n = here_bits + 2;
						while (bits < n) {
							if (have === 0) break inf_leave;
							have--;
							hold += input[next++] << bits;
							bits += 8;
						}
						hold >>>= here_bits;
						bits -= here_bits;
						if (state.have === 0) {
							strm.msg = "invalid bit length repeat";
							state.mode = BAD;
							break;
						}
						len = state.lens[state.have - 1];
						copy = 3 + (hold & 3);
						hold >>>= 2;
						bits -= 2;
					} else if (here_val === 17) {
						n = here_bits + 3;
						while (bits < n) {
							if (have === 0) break inf_leave;
							have--;
							hold += input[next++] << bits;
							bits += 8;
						}
						hold >>>= here_bits;
						bits -= here_bits;
						len = 0;
						copy = 3 + (hold & 7);
						hold >>>= 3;
						bits -= 3;
					} else {
						n = here_bits + 7;
						while (bits < n) {
							if (have === 0) break inf_leave;
							have--;
							hold += input[next++] << bits;
							bits += 8;
						}
						hold >>>= here_bits;
						bits -= here_bits;
						len = 0;
						copy = 11 + (hold & 127);
						hold >>>= 7;
						bits -= 7;
					}
					if (state.have + copy > state.nlen + state.ndist) {
						strm.msg = "invalid bit length repeat";
						state.mode = BAD;
						break;
					}
					while (copy--) state.lens[state.have++] = len;
				}
			}
			if (state.mode === BAD) break;
			if (state.lens[256] === 0) {
				strm.msg = "invalid code -- missing end-of-block";
				state.mode = BAD;
				break;
			}
			state.lenbits = 9;
			opts = { bits: state.lenbits };
			ret = inftrees(LENS, state.lens, 0, state.nlen, state.lencode, 0, state.work, opts);
			state.lenbits = opts.bits;
			if (ret) {
				strm.msg = "invalid literal/lengths set";
				state.mode = BAD;
				break;
			}
			state.distbits = 6;
			state.distcode = state.distdyn;
			opts = { bits: state.distbits };
			ret = inftrees(DISTS, state.lens, state.nlen, state.ndist, state.distcode, 0, state.work, opts);
			state.distbits = opts.bits;
			if (ret) {
				strm.msg = "invalid distances set";
				state.mode = BAD;
				break;
			}
			state.mode = LEN_;
			if (flush === Z_TREES) break inf_leave;
		case LEN_: state.mode = LEN;
		case LEN:
			if (have >= 6 && left >= 258) {
				strm.next_out = put;
				strm.avail_out = left;
				strm.next_in = next;
				strm.avail_in = have;
				state.hold = hold;
				state.bits = bits;
				inffast(strm, _out);
				put = strm.next_out;
				output = strm.output;
				left = strm.avail_out;
				next = strm.next_in;
				input = strm.input;
				have = strm.avail_in;
				hold = state.hold;
				bits = state.bits;
				if (state.mode === TYPE) state.back = -1;
				break;
			}
			state.back = 0;
			for (;;) {
				here = state.lencode[hold & (1 << state.lenbits) - 1];
				here_bits = here >>> 24;
				here_op = here >>> 16 & 255;
				here_val = here & 65535;
				if (here_bits <= bits) break;
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			if (here_op && (here_op & 240) === 0) {
				last_bits = here_bits;
				last_op = here_op;
				last_val = here_val;
				for (;;) {
					here = state.lencode[last_val + ((hold & (1 << last_bits + last_op) - 1) >> last_bits)];
					here_bits = here >>> 24;
					here_op = here >>> 16 & 255;
					here_val = here & 65535;
					if (last_bits + here_bits <= bits) break;
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				hold >>>= last_bits;
				bits -= last_bits;
				state.back += last_bits;
			}
			hold >>>= here_bits;
			bits -= here_bits;
			state.back += here_bits;
			state.length = here_val;
			if (here_op === 0) {
				state.mode = LIT;
				break;
			}
			if (here_op & 32) {
				state.back = -1;
				state.mode = TYPE;
				break;
			}
			if (here_op & 64) {
				strm.msg = "invalid literal/length code";
				state.mode = BAD;
				break;
			}
			state.extra = here_op & 15;
			state.mode = LENEXT;
		case LENEXT:
			if (state.extra) {
				n = state.extra;
				while (bits < n) {
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				state.length += hold & (1 << state.extra) - 1;
				hold >>>= state.extra;
				bits -= state.extra;
				state.back += state.extra;
			}
			state.was = state.length;
			state.mode = DIST;
		case DIST:
			for (;;) {
				here = state.distcode[hold & (1 << state.distbits) - 1];
				here_bits = here >>> 24;
				here_op = here >>> 16 & 255;
				here_val = here & 65535;
				if (here_bits <= bits) break;
				if (have === 0) break inf_leave;
				have--;
				hold += input[next++] << bits;
				bits += 8;
			}
			if ((here_op & 240) === 0) {
				last_bits = here_bits;
				last_op = here_op;
				last_val = here_val;
				for (;;) {
					here = state.distcode[last_val + ((hold & (1 << last_bits + last_op) - 1) >> last_bits)];
					here_bits = here >>> 24;
					here_op = here >>> 16 & 255;
					here_val = here & 65535;
					if (last_bits + here_bits <= bits) break;
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				hold >>>= last_bits;
				bits -= last_bits;
				state.back += last_bits;
			}
			hold >>>= here_bits;
			bits -= here_bits;
			state.back += here_bits;
			if (here_op & 64) {
				strm.msg = "invalid distance code";
				state.mode = BAD;
				break;
			}
			state.offset = here_val;
			state.extra = here_op & 15;
			state.mode = DISTEXT;
		case DISTEXT:
			if (state.extra) {
				n = state.extra;
				while (bits < n) {
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				state.offset += hold & (1 << state.extra) - 1;
				hold >>>= state.extra;
				bits -= state.extra;
				state.back += state.extra;
			}
			if (state.offset > state.dmax) {
				strm.msg = "invalid distance too far back";
				state.mode = BAD;
				break;
			}
			state.mode = MATCH;
		case MATCH:
			if (left === 0) break inf_leave;
			copy = _out - left;
			if (state.offset > copy) {
				copy = state.offset - copy;
				if (copy > state.whave) {
					if (state.sane) {
						strm.msg = "invalid distance too far back";
						state.mode = BAD;
						break;
					}
				}
				if (copy > state.wnext) {
					copy -= state.wnext;
					from = state.wsize - copy;
				} else from = state.wnext - copy;
				if (copy > state.length) copy = state.length;
				from_source = state.window;
			} else {
				from_source = output;
				from = put - state.offset;
				copy = state.length;
			}
			if (copy > left) copy = left;
			left -= copy;
			state.length -= copy;
			do
				output[put++] = from_source[from++];
			while (--copy);
			if (state.length === 0) state.mode = LEN;
			break;
		case LIT:
			if (left === 0) break inf_leave;
			output[put++] = state.length;
			left--;
			state.mode = LEN;
			break;
		case CHECK:
			if (state.wrap) {
				while (bits < 32) {
					if (have === 0) break inf_leave;
					have--;
					hold |= input[next++] << bits;
					bits += 8;
				}
				_out -= left;
				strm.total_out += _out;
				state.total += _out;
				if (state.wrap & 4 && _out) strm.adler = state.check = state.flags ? crc32_1(state.check, output, _out, put - _out) : adler32_1(state.check, output, _out, put - _out);
				_out = left;
				if (state.wrap & 4 && (state.flags ? hold : zswap32(hold)) !== state.check) {
					strm.msg = "incorrect data check";
					state.mode = BAD;
					break;
				}
				hold = 0;
				bits = 0;
			}
			state.mode = LENGTH;
		case LENGTH:
			if (state.wrap && state.flags) {
				while (bits < 32) {
					if (have === 0) break inf_leave;
					have--;
					hold += input[next++] << bits;
					bits += 8;
				}
				if (state.wrap & 4 && hold !== (state.total & 4294967295)) {
					strm.msg = "incorrect length check";
					state.mode = BAD;
					break;
				}
				hold = 0;
				bits = 0;
			}
			state.mode = DONE;
		case DONE:
			ret = Z_STREAM_END$1;
			break inf_leave;
		case BAD:
			ret = Z_DATA_ERROR$1;
			break inf_leave;
		case MEM: return Z_MEM_ERROR$1;
		case SYNC:
		default: return Z_STREAM_ERROR$1;
	}
	strm.next_out = put;
	strm.avail_out = left;
	strm.next_in = next;
	strm.avail_in = have;
	state.hold = hold;
	state.bits = bits;
	if (state.wsize || _out !== strm.avail_out && state.mode < BAD && (state.mode < CHECK || flush !== Z_FINISH$1)) {
		if (updatewindow(strm, strm.output, strm.next_out, _out - strm.avail_out));
	}
	_in -= strm.avail_in;
	_out -= strm.avail_out;
	strm.total_in += _in;
	strm.total_out += _out;
	state.total += _out;
	if (state.wrap & 4 && _out) strm.adler = state.check = state.flags ? crc32_1(state.check, output, _out, strm.next_out - _out) : adler32_1(state.check, output, _out, strm.next_out - _out);
	strm.data_type = state.bits + (state.last ? 64 : 0) + (state.mode === TYPE ? 128 : 0) + (state.mode === LEN_ || state.mode === COPY_ ? 256 : 0);
	if ((_in === 0 && _out === 0 || flush === Z_FINISH$1) && ret === Z_OK$1) ret = Z_BUF_ERROR;
	return ret;
};
const inflateEnd = (strm) => {
	if (inflateStateCheck(strm)) return Z_STREAM_ERROR$1;
	let state = strm.state;
	if (state.window) state.window = null;
	strm.state = null;
	return Z_OK$1;
};
const inflateGetHeader = (strm, head) => {
	if (inflateStateCheck(strm)) return Z_STREAM_ERROR$1;
	const state = strm.state;
	if ((state.wrap & 2) === 0) return Z_STREAM_ERROR$1;
	state.head = head;
	head.done = false;
	return Z_OK$1;
};
const inflateSetDictionary = (strm, dictionary) => {
	const dictLength = dictionary.length;
	let state;
	let dictid;
	let ret;
	if (inflateStateCheck(strm)) return Z_STREAM_ERROR$1;
	state = strm.state;
	if (state.wrap !== 0 && state.mode !== DICT) return Z_STREAM_ERROR$1;
	if (state.mode === DICT) {
		dictid = 1;
		dictid = adler32_1(dictid, dictionary, dictLength, 0);
		if (dictid !== state.check) return Z_DATA_ERROR$1;
	}
	ret = updatewindow(strm, dictionary, dictLength, dictLength);
	if (ret) {
		state.mode = MEM;
		return Z_MEM_ERROR$1;
	}
	state.havedict = 1;
	return Z_OK$1;
};
var inflate_1$2 = {
	inflateReset,
	inflateReset2,
	inflateResetKeep,
	inflateInit,
	inflateInit2,
	inflate: inflate$2,
	inflateEnd,
	inflateGetHeader,
	inflateSetDictionary,
	inflateInfo: "pako inflate (from Nodeca project)"
};
function GZheader() {
	this.text = 0;
	this.time = 0;
	this.xflags = 0;
	this.os = 0;
	this.extra = null;
	this.extra_len = 0;
	this.name = "";
	this.comment = "";
	this.hcrc = 0;
	this.done = false;
}
var gzheader = GZheader;
const toString = Object.prototype.toString;
const { Z_NO_FLUSH, Z_FINISH, Z_OK, Z_STREAM_END, Z_NEED_DICT, Z_STREAM_ERROR, Z_DATA_ERROR, Z_MEM_ERROR } = constants$2;
/**
* class Inflate
*
* Generic JS-style wrapper for zlib calls. If you don't need
* streaming behaviour - use more simple functions: [[inflate]]
* and [[inflateRaw]].
**/
/**
* Inflate.result -> Uint8Array|String
*
* Uncompressed result, generated by default [[Inflate#onData]]
* and [[Inflate#onEnd]] handlers. Filled after you push last chunk
* (call [[Inflate#push]] with `Z_FINISH` / `true` param).
**/
/**
* Inflate.err -> Number
*
* Error code after inflate finished. 0 (Z_OK) on success.
* Should be checked if broken data possible.
**/
/**
* Inflate.msg -> String
*
* Error message, if [[Inflate.err]] != 0
**/
/**
* new Inflate(options)
* - options (Object): zlib inflate options.
*
* Creates new inflator instance with specified params. Throws exception
* on bad params. Supported options:
*
* - `windowBits`
* - `dictionary`
*
* [http://zlib.net/manual.html#Advanced](http://zlib.net/manual.html#Advanced)
* for more information on these.
*
* Additional options, for internal needs:
*
* - `chunkSize` - size of generated data chunks (16K by default)
* - `raw` (Boolean) - do raw inflate
* - `to` (String) - if equal to 'string', then result will be converted
*   from utf8 to utf16 (javascript) string. When string output requested,
*   chunk length can differ from `chunkSize`, depending on content.
*
* By default, when no options set, autodetect deflate/gzip data format via
* wrapper header.
*
* ##### Example:
*
* ```javascript
* const pako = require('pako')
* const chunk1 = new Uint8Array([1,2,3,4,5,6,7,8,9])
* const chunk2 = new Uint8Array([10,11,12,13,14,15,16,17,18,19]);
*
* const inflate = new pako.Inflate({ level: 3});
*
* inflate.push(chunk1, false);
* inflate.push(chunk2, true);  // true -> last chunk
*
* if (inflate.err) { throw new Error(inflate.err); }
*
* console.log(inflate.result);
* ```
**/
function Inflate$1(options) {
	this.options = common.assign({
		chunkSize: 1024 * 64,
		windowBits: 15,
		to: ""
	}, options || {});
	const opt = this.options;
	if (opt.raw && opt.windowBits >= 0 && opt.windowBits < 16) {
		opt.windowBits = -opt.windowBits;
		if (opt.windowBits === 0) opt.windowBits = -15;
	}
	if (opt.windowBits >= 0 && opt.windowBits < 16 && !(options && options.windowBits)) opt.windowBits += 32;
	if (opt.windowBits > 15 && opt.windowBits < 48) {
		if ((opt.windowBits & 15) === 0) opt.windowBits |= 15;
	}
	this.err = 0;
	this.msg = "";
	this.ended = false;
	this.chunks = [];
	this.strm = new zstream();
	this.strm.avail_out = 0;
	let status = inflate_1$2.inflateInit2(this.strm, opt.windowBits);
	if (status !== Z_OK) throw new Error(messages[status]);
	this.header = new gzheader();
	inflate_1$2.inflateGetHeader(this.strm, this.header);
	if (opt.dictionary) {
		if (typeof opt.dictionary === "string") opt.dictionary = strings.string2buf(opt.dictionary);
		else if (toString.call(opt.dictionary) === "[object ArrayBuffer]") opt.dictionary = new Uint8Array(opt.dictionary);
		if (opt.raw) {
			status = inflate_1$2.inflateSetDictionary(this.strm, opt.dictionary);
			if (status !== Z_OK) throw new Error(messages[status]);
		}
	}
}
/**
* Inflate#push(data[, flush_mode]) -> Boolean
* - data (Uint8Array|ArrayBuffer): input data
* - flush_mode (Number|Boolean): 0..6 for corresponding Z_NO_FLUSH..Z_TREE
*   flush modes. See constants. Skipped or `false` means Z_NO_FLUSH,
*   `true` means Z_FINISH.
*
* Sends input data to inflate pipe, generating [[Inflate#onData]] calls with
* new output chunks. Returns `true` on success. If end of stream detected,
* [[Inflate#onEnd]] will be called.
*
* `flush_mode` is not needed for normal operation, because end of stream
* detected automatically. You may try to use it for advanced things, but
* this functionality was not tested.
*
* On fail call [[Inflate#onEnd]] with error code and return false.
*
* ##### Example
*
* ```javascript
* push(chunk, false); // push one of data chunks
* ...
* push(chunk, true);  // push last chunk
* ```
**/
Inflate$1.prototype.push = function(data, flush_mode) {
	const strm = this.strm;
	const chunkSize = this.options.chunkSize;
	const dictionary = this.options.dictionary;
	let status, _flush_mode, last_avail_out;
	if (this.ended) return false;
	if (flush_mode === ~~flush_mode) _flush_mode = flush_mode;
	else _flush_mode = flush_mode === true ? Z_FINISH : Z_NO_FLUSH;
	if (toString.call(data) === "[object ArrayBuffer]") strm.input = new Uint8Array(data);
	else strm.input = data;
	strm.next_in = 0;
	strm.avail_in = strm.input.length;
	for (;;) {
		if (strm.avail_out === 0) {
			strm.output = new Uint8Array(chunkSize);
			strm.next_out = 0;
			strm.avail_out = chunkSize;
		}
		status = inflate_1$2.inflate(strm, _flush_mode);
		if (status === Z_NEED_DICT && dictionary) {
			status = inflate_1$2.inflateSetDictionary(strm, dictionary);
			if (status === Z_OK) status = inflate_1$2.inflate(strm, _flush_mode);
			else if (status === Z_DATA_ERROR) status = Z_NEED_DICT;
		}
		while (strm.avail_in > 0 && status === Z_STREAM_END && strm.state.wrap > 0 && data[strm.next_in] !== 0) {
			inflate_1$2.inflateReset(strm);
			status = inflate_1$2.inflate(strm, _flush_mode);
		}
		switch (status) {
			case Z_STREAM_ERROR:
			case Z_DATA_ERROR:
			case Z_NEED_DICT:
			case Z_MEM_ERROR:
				this.onEnd(status);
				this.ended = true;
				return false;
		}
		last_avail_out = strm.avail_out;
		if (strm.next_out) {
			if (strm.avail_out === 0 || status === Z_STREAM_END) if (this.options.to === "string") {
				let next_out_utf8 = strings.utf8border(strm.output, strm.next_out);
				let tail = strm.next_out - next_out_utf8;
				let utf8str = strings.buf2string(strm.output, next_out_utf8);
				strm.next_out = tail;
				strm.avail_out = chunkSize - tail;
				if (tail) strm.output.set(strm.output.subarray(next_out_utf8, next_out_utf8 + tail), 0);
				this.onData(utf8str);
			} else this.onData(strm.output.length === strm.next_out ? strm.output : strm.output.subarray(0, strm.next_out));
		}
		if (status === Z_OK && last_avail_out === 0) continue;
		if (status === Z_STREAM_END) {
			status = inflate_1$2.inflateEnd(this.strm);
			this.onEnd(status);
			this.ended = true;
			return true;
		}
		if (strm.avail_in === 0) break;
	}
	return true;
};
/**
* Inflate#onData(chunk) -> Void
* - chunk (Uint8Array|String): output data. When string output requested,
*   each chunk will be string.
*
* By default, stores data blocks in `chunks[]` property and glue
* those in `onEnd`. Override this handler, if you need another behaviour.
**/
Inflate$1.prototype.onData = function(chunk) {
	this.chunks.push(chunk);
};
/**
* Inflate#onEnd(status) -> Void
* - status (Number): inflate status. 0 (Z_OK) on success,
*   other if not.
*
* Called either after you tell inflate that the input stream is
* complete (Z_FINISH). By default - join collected chunks,
* free memory and fill `results` / `err` properties.
**/
Inflate$1.prototype.onEnd = function(status) {
	if (status === Z_OK) if (this.options.to === "string") this.result = this.chunks.join("");
	else this.result = common.flattenChunks(this.chunks);
	this.chunks = [];
	this.err = status;
	this.msg = this.strm.msg;
};
/**
* inflate(data[, options]) -> Uint8Array|String
* - data (Uint8Array|ArrayBuffer): input data to decompress.
* - options (Object): zlib inflate options.
*
* Decompress `data` with inflate/ungzip and `options`. Autodetect
* format via wrapper header by default. That's why we don't provide
* separate `ungzip` method.
*
* Supported options are:
*
* - windowBits
*
* [http://zlib.net/manual.html#Advanced](http://zlib.net/manual.html#Advanced)
* for more information.
*
* Sugar (options):
*
* - `raw` (Boolean) - say that we work with raw stream, if you don't wish to specify
*   negative windowBits implicitly.
* - `to` (String) - if equal to 'string', then result will be converted
*   from utf8 to utf16 (javascript) string. When string output requested,
*   chunk length can differ from `chunkSize`, depending on content.
*
*
* ##### Example:
*
* ```javascript
* const pako = require('pako');
* const input = pako.deflate(new Uint8Array([1,2,3,4,5,6,7,8,9]));
* let output;
*
* try {
*   output = pako.inflate(input);
* } catch (err) {
*   console.log(err);
* }
* ```
**/
function inflate$1(input, options) {
	const inflator = new Inflate$1(options);
	inflator.push(input);
	if (inflator.err) throw inflator.msg || messages[inflator.err];
	return inflator.result;
}
/**
* inflateRaw(data[, options]) -> Uint8Array|String
* - data (Uint8Array|ArrayBuffer): input data to decompress.
* - options (Object): zlib inflate options.
*
* The same as [[inflate]], but creates raw data, without wrapper
* (header and adler32 crc).
**/
function inflateRaw$1(input, options) {
	options = options || {};
	options.raw = true;
	return inflate$1(input, options);
}
var inflate_1$1 = {
	Inflate: Inflate$1,
	inflate: inflate$1,
	inflateRaw: inflateRaw$1,
	ungzip: inflate$1,
	constants: constants$2
};
const { Deflate, deflate, deflateRaw, gzip } = deflate_1$1;
const { Inflate, inflate, inflateRaw, ungzip } = inflate_1$1;
var deflate_1 = deflate;
var inflate_1 = inflate;
//#endregion
//#region src/formats/eqrc/constants.ts
/**
* @internal
* @module constants
* @description
* 包含了所有 `custom_des` 模块所需的常量数据。
*/
const KEY_1 = new TextEncoder().encode("!@#)(*$%");
const KEY_2 = new TextEncoder().encode("123ZXC!@");
const KEY_3 = new TextEncoder().encode("!@#)(NHL");
const S_BOXES = [
	[
		14,
		4,
		13,
		1,
		2,
		15,
		11,
		8,
		3,
		10,
		6,
		12,
		5,
		9,
		0,
		7,
		0,
		15,
		7,
		4,
		14,
		2,
		13,
		1,
		10,
		6,
		12,
		11,
		9,
		5,
		3,
		8,
		4,
		1,
		14,
		8,
		13,
		6,
		2,
		11,
		15,
		12,
		9,
		7,
		3,
		10,
		5,
		0,
		15,
		12,
		8,
		2,
		4,
		9,
		1,
		7,
		5,
		11,
		3,
		14,
		10,
		0,
		6,
		13
	],
	[
		15,
		1,
		8,
		14,
		6,
		11,
		3,
		4,
		9,
		7,
		2,
		13,
		12,
		0,
		5,
		10,
		3,
		13,
		4,
		7,
		15,
		2,
		8,
		15,
		12,
		0,
		1,
		10,
		6,
		9,
		11,
		5,
		0,
		14,
		7,
		11,
		10,
		4,
		13,
		1,
		5,
		8,
		12,
		6,
		9,
		3,
		2,
		15,
		13,
		8,
		10,
		1,
		3,
		15,
		4,
		2,
		11,
		6,
		7,
		12,
		0,
		5,
		14,
		9
	],
	[
		10,
		0,
		9,
		14,
		6,
		3,
		15,
		5,
		1,
		13,
		12,
		7,
		11,
		4,
		2,
		8,
		13,
		7,
		0,
		9,
		3,
		4,
		6,
		10,
		2,
		8,
		5,
		14,
		12,
		11,
		15,
		1,
		13,
		6,
		4,
		9,
		8,
		15,
		3,
		0,
		11,
		1,
		2,
		12,
		5,
		10,
		14,
		7,
		1,
		10,
		13,
		0,
		6,
		9,
		8,
		7,
		4,
		15,
		14,
		3,
		11,
		5,
		2,
		12
	],
	[
		7,
		13,
		14,
		3,
		0,
		6,
		9,
		10,
		1,
		2,
		8,
		5,
		11,
		12,
		4,
		15,
		13,
		8,
		11,
		5,
		6,
		15,
		0,
		3,
		4,
		7,
		2,
		12,
		1,
		10,
		14,
		9,
		10,
		6,
		9,
		0,
		12,
		11,
		7,
		13,
		15,
		1,
		3,
		14,
		5,
		2,
		8,
		4,
		3,
		15,
		0,
		6,
		10,
		10,
		13,
		8,
		9,
		4,
		5,
		11,
		12,
		7,
		2,
		14
	],
	[
		2,
		12,
		4,
		1,
		7,
		10,
		11,
		6,
		8,
		5,
		3,
		15,
		13,
		0,
		14,
		9,
		14,
		11,
		2,
		12,
		4,
		7,
		13,
		1,
		5,
		0,
		15,
		10,
		3,
		9,
		8,
		6,
		4,
		2,
		1,
		11,
		10,
		13,
		7,
		8,
		15,
		9,
		12,
		5,
		6,
		3,
		0,
		14,
		11,
		8,
		12,
		7,
		1,
		14,
		2,
		13,
		6,
		15,
		0,
		9,
		10,
		4,
		5,
		3
	],
	[
		12,
		1,
		10,
		15,
		9,
		2,
		6,
		8,
		0,
		13,
		3,
		4,
		14,
		7,
		5,
		11,
		10,
		15,
		4,
		2,
		7,
		12,
		9,
		5,
		6,
		1,
		13,
		14,
		0,
		11,
		3,
		8,
		9,
		14,
		15,
		5,
		2,
		8,
		12,
		3,
		7,
		0,
		4,
		10,
		1,
		13,
		11,
		6,
		4,
		3,
		2,
		12,
		9,
		5,
		15,
		10,
		11,
		14,
		1,
		7,
		6,
		0,
		8,
		13
	],
	[
		4,
		11,
		2,
		14,
		15,
		0,
		8,
		13,
		3,
		12,
		9,
		7,
		5,
		10,
		6,
		1,
		13,
		0,
		11,
		7,
		4,
		9,
		1,
		10,
		14,
		3,
		5,
		12,
		2,
		15,
		8,
		6,
		1,
		4,
		11,
		13,
		12,
		3,
		7,
		14,
		10,
		15,
		6,
		8,
		0,
		5,
		9,
		2,
		6,
		11,
		13,
		8,
		1,
		4,
		10,
		7,
		9,
		5,
		0,
		15,
		14,
		2,
		3,
		12
	],
	[
		13,
		2,
		8,
		4,
		6,
		15,
		11,
		1,
		10,
		9,
		3,
		14,
		5,
		0,
		12,
		7,
		1,
		15,
		13,
		8,
		10,
		3,
		7,
		4,
		12,
		5,
		6,
		11,
		0,
		14,
		9,
		2,
		7,
		11,
		4,
		1,
		9,
		12,
		14,
		2,
		0,
		6,
		10,
		13,
		15,
		3,
		5,
		8,
		2,
		1,
		14,
		7,
		4,
		10,
		8,
		13,
		15,
		12,
		9,
		0,
		3,
		5,
		6,
		11
	]
];
const P_BOX = [
	16,
	7,
	20,
	21,
	29,
	12,
	28,
	17,
	1,
	15,
	23,
	26,
	5,
	18,
	31,
	10,
	2,
	8,
	24,
	14,
	32,
	27,
	3,
	9,
	19,
	13,
	30,
	6,
	22,
	11,
	4,
	25
];
const E_BOX_TABLE = [
	32,
	1,
	2,
	3,
	4,
	5,
	4,
	5,
	6,
	7,
	8,
	9,
	8,
	9,
	10,
	11,
	12,
	13,
	12,
	13,
	14,
	15,
	16,
	17,
	16,
	17,
	18,
	19,
	20,
	21,
	20,
	21,
	22,
	23,
	24,
	25,
	24,
	25,
	26,
	27,
	28,
	29,
	28,
	29,
	30,
	31,
	32,
	1
];
const KEY_RND_SHIFT = [
	1,
	1,
	2,
	2,
	2,
	2,
	2,
	2,
	1,
	2,
	2,
	2,
	2,
	2,
	2,
	1
];
const KEY_PERM_C = [
	56,
	48,
	40,
	32,
	24,
	16,
	8,
	0,
	57,
	49,
	41,
	33,
	25,
	17,
	9,
	1,
	58,
	50,
	42,
	34,
	26,
	18,
	10,
	2,
	59,
	51,
	43,
	35
];
const KEY_PERM_D = [
	62,
	54,
	46,
	38,
	30,
	22,
	14,
	6,
	61,
	53,
	45,
	37,
	29,
	21,
	13,
	5,
	60,
	52,
	44,
	36,
	28,
	20,
	12,
	4,
	27,
	19,
	11,
	3
];
const KEY_COMPRESSION = [
	13,
	16,
	10,
	23,
	0,
	4,
	2,
	27,
	14,
	5,
	20,
	9,
	22,
	18,
	11,
	3,
	25,
	7,
	15,
	6,
	26,
	19,
	12,
	1,
	40,
	51,
	30,
	36,
	46,
	54,
	29,
	39,
	50,
	44,
	32,
	47,
	43,
	48,
	38,
	55,
	33,
	52,
	45,
	41,
	49,
	35,
	28,
	31
];
//#endregion
//#region src/formats/eqrc/custom-des.ts
/**
* @internal
* @module custom_des
* @description
* 本模块包含了为解密 QRC 歌词而移植的、非标准的类 DES 算法的底层实现。
*
* <h2>
* <strong>警告：该 DES 实现并非标准实现！</strong>
* </h2>
*
* 它是结构类似DES的、但完全私有的分组密码算法。
* 本实现仅用于 QRC 歌词解密，不应用于实际安全目的。
*/
/**
* 从8字节密钥中根据置换表提取位，生成一个 BigInt。
*
* 这个函数对应原始C代码中的天书BITNUM宏，模拟 QQ 音乐特有的非标准的字节序处理方式。
* 其将 8 字节密钥视为两个独立的、小端序的32位整数拼接而成。
*
* 例如，要读取第0位（MSB），它实际访问的是 `key[3]` 的最高位。
* 要读取第31位，它访问的是 `key[0]` 的最低位。
*
* @param key 8字节的密钥 Uint8Array
* @param table 0-based 的位索引置换表
*/
function permuteFromKeyBytes(key, table) {
	let output = 0n;
	let currentBitMask = 1n << BigInt(table.length - 1);
	for (let i = 0; i < table.length; i++) {
		const pos = table[i];
		const wordIndex = pos >> 5;
		const bitInWord = pos & 31;
		const byteInWord = bitInWord >> 3;
		const bitInByte = bitInWord & 7;
		if (key[wordIndex * 4 + 3 - byteInWord] >> 7 - bitInByte & 1) output |= currentBitMask;
		currentBitMask >>= 1n;
	}
	return output;
}
/**
* 对一个存储在 BigInt 中的28位密钥部分进行循环左移。
* @param value 包含28位数据的高位的 BigInt
* @param amount 左移的位数
*/
function rotateLeft28Bit(value, amount) {
	const BITS_28_MASK = 4294967280n;
	const val = value & BITS_28_MASK;
	return (val << BigInt(amount) | val >> BigInt(28 - amount)) & BITS_28_MASK;
}
/**
* DES 密钥调度算法。
* 从一个64位的主密钥（实际使用56位，每字节的最低位是奇偶校验位，被忽略）
* 生成16个48位的轮密钥。
*
* @param key 8字节的DES密钥
* @param mode 加密或解密模式
*/
function keySchedule(key, mode) {
	const schedule = new Int32Array(32);
	const c0 = permuteFromKeyBytes(key, KEY_PERM_C);
	const d0 = permuteFromKeyBytes(key, KEY_PERM_D);
	let c = c0 << 4n;
	let d = d0 << 4n;
	for (let i = 0; i < 16; i++) {
		const shift = KEY_RND_SHIFT[i];
		c = rotateLeft28Bit(c, shift);
		d = rotateLeft28Bit(d, shift);
		const toGen = mode === 1 ? 15 - i : i;
		let subkey48bit = 0n;
		for (let k = 0; k < KEY_COMPRESSION.length; k++) {
			const pos = KEY_COMPRESSION[k];
			if ((pos < 28 ? c >> BigInt(31 - pos) & 1n : d >> BigInt(31 - (pos - 27)) & 1n) === 1n) subkey48bit |= 1n << BigInt(47 - k);
		}
		const b5 = Number(subkey48bit >> 40n & 255n);
		const b4 = Number(subkey48bit >> 32n & 255n);
		const b3 = Number(subkey48bit >> 24n & 255n);
		const high24 = b5 << 16 | b4 << 8 | b3;
		const b2 = Number(subkey48bit >> 16n & 255n);
		const b1 = Number(subkey48bit >> 8n & 255n);
		const b0 = Number(subkey48bit & 255n);
		const low24 = b2 << 16 | b1 << 8 | b0;
		schedule[toGen * 2] = high24;
		schedule[toGen * 2 + 1] = low24;
	}
	return schedule;
}
const IP_RULE = [
	34,
	42,
	50,
	58,
	2,
	10,
	18,
	26,
	36,
	44,
	52,
	60,
	4,
	12,
	20,
	28,
	38,
	46,
	54,
	62,
	6,
	14,
	22,
	30,
	40,
	48,
	56,
	64,
	8,
	16,
	24,
	32,
	33,
	41,
	49,
	57,
	1,
	9,
	17,
	25,
	35,
	43,
	51,
	59,
	3,
	11,
	19,
	27,
	37,
	45,
	53,
	61,
	5,
	13,
	21,
	29,
	39,
	47,
	55,
	63,
	7,
	15,
	23,
	31
];
const INV_IP_RULE = [
	37,
	5,
	45,
	13,
	53,
	21,
	61,
	29,
	38,
	6,
	46,
	14,
	54,
	22,
	62,
	30,
	39,
	7,
	47,
	15,
	55,
	23,
	63,
	31,
	40,
	8,
	48,
	16,
	56,
	24,
	64,
	32,
	33,
	1,
	41,
	9,
	49,
	17,
	57,
	25,
	34,
	2,
	42,
	10,
	50,
	18,
	58,
	26,
	35,
	3,
	43,
	11,
	51,
	19,
	59,
	27,
	36,
	4,
	44,
	12,
	52,
	20,
	60,
	28
];
const IP_LEFT_TABLE = new Int32Array(2048);
const IP_RIGHT_TABLE = new Int32Array(2048);
const INV_IP_LEFT_TABLE = new Int32Array(2048);
const INV_IP_RIGHT_TABLE = new Int32Array(2048);
function generatePermutationTables() {
	const applyPermutation = (input, rule) => {
		let output = 0n;
		for (let i = 0; i < 64; i++) {
			const srcBit1Based = rule[i];
			if (input >> BigInt(64 - srcBit1Based) & 1n) output |= 1n << BigInt(63 - i);
		}
		return output;
	};
	for (let bytePos = 0; bytePos < 8; bytePos++) for (let byteVal = 0; byteVal < 256; byteVal++) {
		const permuted = applyPermutation(BigInt(byteVal) << BigInt(56 - bytePos * 8), IP_RULE);
		const idx = bytePos << 8 | byteVal;
		IP_LEFT_TABLE[idx] = Number(permuted >> 32n & 4294967295n);
		IP_RIGHT_TABLE[idx] = Number(permuted & 4294967295n);
	}
	for (let blockPos = 0; blockPos < 8; blockPos++) for (let blockVal = 0; blockVal < 256; blockVal++) {
		const permuted = applyPermutation(BigInt(blockVal) << BigInt(56 - blockPos * 8), INV_IP_RULE);
		const idx = blockPos << 8 | blockVal;
		INV_IP_LEFT_TABLE[idx] = Number(permuted >> 32n & 4294967295n);
		INV_IP_RIGHT_TABLE[idx] = Number(permuted & 4294967295n);
	}
}
generatePermutationTables();
/**
* 计算 DES S-盒的查找索引。
* @param a 一个包含6位数据的 u8
*/
function calculateSboxIndex(a) {
	return a & 32 | (a & 31) >> 1 | (a & 1) << 4;
}
/**
* 对一个 32 位整数应用非标准的 P 盒置换规则。
* @param input S-盒代换后的 32 位中间结果
*/
function applyQqPboxPermutation(input) {
	let output = 0;
	for (let i = 0; i < 32; i++) {
		const sourceBit1Based = P_BOX[i];
		const destBitMask = 1 << 31 - i;
		if ((input & 1 << 32 - sourceBit1Based) !== 0) output |= destBitMask;
	}
	return output;
}
const SP_TABLE = new Int32Array(512);
/**
* 生成 S-P 盒合并查找表以提高性能。
*/
function generateSpTables() {
	for (let sBoxIdx = 0; sBoxIdx < 8; sBoxIdx++) for (let sBoxInput = 0; sBoxInput < 64; sBoxInput++) {
		const sBoxIndex = calculateSboxIndex(sBoxInput);
		const prePBoxVal = S_BOXES[sBoxIdx][sBoxIndex] << 28 - sBoxIdx * 4;
		SP_TABLE[sBoxIdx << 6 | sBoxInput] = applyQqPboxPermutation(prePBoxVal);
	}
}
generateSpTables();
const EBOX_HIGH_TABLE = new Int32Array(1024);
const EBOX_LOW_TABLE = new Int32Array(1024);
function generateEBoxTables() {
	for (let chunkIdx = 0; chunkIdx < 4; chunkIdx++) {
		const shiftIn32 = (3 - chunkIdx) * 8;
		for (let byteVal = 0; byteVal < 256; byteVal++) {
			let high24 = 0;
			let low24 = 0;
			const input = byteVal << shiftIn32;
			for (let i = 0; i < 24; i++) if (input >>> 32 - E_BOX_TABLE[i] & 1) high24 |= 1 << 23 - i;
			for (let i = 24; i < 48; i++) if (input >>> 32 - E_BOX_TABLE[i] & 1) low24 |= 1 << 47 - i;
			const tableIdx = chunkIdx << 8 | byteVal;
			EBOX_HIGH_TABLE[tableIdx] = high24;
			EBOX_LOW_TABLE[tableIdx] = low24;
		}
	}
}
generateEBoxTables();
/**
* DES 的 F 函数。
*/
function fFunction(state, keyHigh24, keyLow24) {
	const b0 = state >>> 24 & 255;
	const b1 = state >>> 16 & 255;
	const b2 = state >>> 8 & 255;
	const b3 = state & 255;
	const eboxHigh24 = EBOX_HIGH_TABLE[b0] | EBOX_HIGH_TABLE[256 | b1] | EBOX_HIGH_TABLE[512 | b2] | EBOX_HIGH_TABLE[768 | b3];
	const eboxLow24 = EBOX_LOW_TABLE[b0] | EBOX_LOW_TABLE[256 | b1] | EBOX_LOW_TABLE[512 | b2] | EBOX_LOW_TABLE[768 | b3];
	const xorHigh24 = eboxHigh24 ^ keyHigh24;
	const xorLow24 = eboxLow24 ^ keyLow24;
	return SP_TABLE[xorHigh24 >>> 18 & 63] | SP_TABLE[64 | xorHigh24 >>> 12 & 63] | SP_TABLE[128 | xorHigh24 >>> 6 & 63] | SP_TABLE[192 | xorHigh24 & 63] | SP_TABLE[256 | xorLow24 >>> 18 & 63] | SP_TABLE[320 | xorLow24 >>> 12 & 63] | SP_TABLE[384 | xorLow24 >>> 6 & 63] | SP_TABLE[448 | xorLow24 & 63];
}
/**
* DES 加密/解密单个64位数据块。
*
* @param input 8字节的输入数据块 (明文或密文)。
* @param output 8字节的可变切片，用于存储输出数据块 (密文或明文)。
* @param keySchedule 一个包含16个轮密钥的向量的引用，每个轮密钥是6字节。
*/
function desCrypt(input, output, keySchedule) {
	let left = 0;
	let right = 0;
	for (let i = 0; i < 8; i++) {
		const idx = i << 8 | input[i];
		left |= IP_LEFT_TABLE[idx];
		right |= IP_RIGHT_TABLE[idx];
	}
	for (let i = 0; i < 15; i++) {
		const temp = right;
		right = (left ^ fFunction(right, keySchedule[i * 2], keySchedule[i * 2 + 1])) >>> 0;
		left = temp;
	}
	left = (left ^ fFunction(right, keySchedule[30], keySchedule[31])) >>> 0;
	let outLeft = 0;
	let outRight = 0;
	for (let i = 0; i < 4; i++) {
		const idxL = i << 8 | left >>> 24 - i * 8 & 255;
		outLeft |= INV_IP_LEFT_TABLE[idxL];
		outRight |= INV_IP_RIGHT_TABLE[idxL];
		const idxR = i + 4 << 8 | right >>> 24 - i * 8 & 255;
		outLeft |= INV_IP_LEFT_TABLE[idxR];
		outRight |= INV_IP_RIGHT_TABLE[idxR];
	}
	output[0] = outLeft >>> 24 & 255;
	output[1] = outLeft >>> 16 & 255;
	output[2] = outLeft >>> 8 & 255;
	output[3] = outLeft & 255;
	output[4] = outRight >>> 24 & 255;
	output[5] = outRight >>> 16 & 255;
	output[6] = outRight >>> 8 & 255;
	output[7] = outRight & 255;
}
//#endregion
//#region src/formats/eqrc/utils.ts
/**
* @module utils
* @description
*
* 包含一些工具函数。
*/
/**
* 将十六进制字符串转换为 Uint8Array。
*/
function hexToUint8Array(hex) {
	if (typeof Buffer !== "undefined") return Buffer.from(hex, "hex");
	if (hex.length % 2 !== 0) throw new Error("无效的十六进制字符串: 长度必须是偶数");
	const bytes = new Uint8Array(hex.length / 2);
	for (let i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
	return bytes;
}
/**
* 将 Uint8Array 转换为十六进制字符串。
*/
function uint8ArrayToHex(bytes) {
	if (typeof Buffer !== "undefined") return Buffer.from(bytes).toString("hex");
	return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}
//#endregion
//#region src/formats/eqrc/index.ts
/**
* @module qrc-codec
* @description
* 此模块是加密与解密 QRC 歌词的核心。
* 提供了两个主要的公共函数：`decryptQrc` 和 `encryptQrc`。
*
* 非标准 3DES 算法实现由 `custom_des` 模块提供。
*
* 迁移自 https://github.com/apoint123/qrc-decoder
*/
const DES_BLOCK_SIZE = 8;
/**
* 非标准 3DES 编解码器
*/
var QqMusicCodec = class {
	encryptSchedule;
	decryptSchedule;
	constructor() {
		this.decryptSchedule = [
			keySchedule(KEY_3, 1),
			keySchedule(KEY_2, 0),
			keySchedule(KEY_1, 1)
		];
		this.encryptSchedule = [
			keySchedule(KEY_1, 0),
			keySchedule(KEY_2, 1),
			keySchedule(KEY_3, 0)
		];
	}
	/**
	* 解密一个8字节的数据块。
	*/
	decryptBlock(input, output) {
		const temp1 = new Uint8Array(8);
		const temp2 = new Uint8Array(8);
		desCrypt(input, temp1, this.decryptSchedule[0]);
		desCrypt(temp1, temp2, this.decryptSchedule[1]);
		desCrypt(temp2, output, this.decryptSchedule[2]);
	}
	/**
	* 加密一个8字节的数据块。
	*/
	encryptBlock(input, output) {
		const temp1 = new Uint8Array(8);
		const temp2 = new Uint8Array(8);
		desCrypt(input, temp1, this.encryptSchedule[0]);
		desCrypt(temp1, temp2, this.encryptSchedule[1]);
		desCrypt(temp2, output, this.encryptSchedule[2]);
	}
};
const CODEC = new QqMusicCodec();
/**
* 使用零字节对数据进行填充。
*
* QQ音乐使用的填充方案是零填充。
* @param data 需要填充的字节数据
* @param blockSize 块大小，对于DES来说是8
*/
function zeroPad(data, blockSize) {
	const paddingLen = (blockSize - data.length % blockSize) % blockSize;
	if (paddingLen === 0) return data;
	const paddedData = new Uint8Array(data.length + paddingLen);
	paddedData.set(data, 0);
	return paddedData;
}
/**
* 使用 Zlib 解压缩字节数据。
* 同时会尝试移除头部的 UTF-8 BOM (0xEF 0xBB 0xBF)。
*/
function decompress(data) {
	const decompressed = inflate_1(data);
	if (decompressed.length >= 3 && decompressed[0] === 239 && decompressed[1] === 187 && decompressed[2] === 191) return decompressed.slice(3);
	return decompressed;
}
/**
* 解密十六进制字符串格式的 Qrc 歌词数据
* 解密后可去头尾 XML 数据后通过调用 `parseQrc` 解析歌词行
* @param encryptedHexString 十六进制格式的字符串，代表被加密的歌词数据
* @returns 被解密出来的歌词字符串，是前后有 XML 混合的 QRC 歌词
*/
function decryptQrcHex(encryptedHexString) {
	const encryptedBytes = hexToUint8Array(encryptedHexString);
	if (encryptedBytes.length % DES_BLOCK_SIZE !== 0) throw new Error(`加密数据长度不是${DES_BLOCK_SIZE}的倍数`);
	const decryptedData = new Uint8Array(encryptedBytes.length);
	for (let i = 0; i < encryptedBytes.length; i += DES_BLOCK_SIZE) {
		const chunk = encryptedBytes.subarray(i, i + DES_BLOCK_SIZE);
		const outChunk = decryptedData.subarray(i, i + DES_BLOCK_SIZE);
		CODEC.decryptBlock(chunk, outChunk);
	}
	const decompressedBytes = decompress(decryptedData);
	return new TextDecoder("utf-8").decode(decompressedBytes);
}
/**
* 对明文执行加密操作。
* @param plaintext 明文字符串
* @returns 十六进制格式的字符串，代表被加密的歌词数据
*/
function encryptQrcHex(plaintext) {
	const paddedData = zeroPad(deflate_1(new TextEncoder().encode(plaintext)), DES_BLOCK_SIZE);
	const encryptedData = new Uint8Array(paddedData.length);
	for (let i = 0; i < paddedData.length; i += DES_BLOCK_SIZE) {
		const chunk = paddedData.subarray(i, i + DES_BLOCK_SIZE);
		const outChunk = encryptedData.subarray(i, i + DES_BLOCK_SIZE);
		CODEC.encryptBlock(chunk, outChunk);
	}
	return uint8ArrayToHex(encryptedData);
}
//#endregion
//#region src/formats/eslrc.ts
const TIME_REGEX = /^\[((?:\d+:)*\d+(?:\.\d+)?)\]/;
function parseTimestampPrefix(src) {
	const match = src.match(TIME_REGEX);
	if (!match) return null;
	const [raw, timeStr] = match;
	return {
		time: parseTime(timeStr),
		length: raw.length
	};
}
function parseEslrcLine(rawLine) {
	let src = rawLine.trim();
	const first = parseTimestampPrefix(src);
	if (!first) return null;
	src = src.slice(first.length);
	let startTime = first.time;
	if (!src.trim()) return null;
	const words = [];
	while (src.trim().length > 0) {
		const nextTimePos = src.indexOf("[");
		if (nextTimePos <= 0) return null;
		const word = src.slice(0, nextTimePos);
		const nextTime = parseTimestampPrefix(src.slice(nextTimePos));
		if (!nextTime) return null;
		words.push(createWord({
			word,
			startTime,
			endTime: nextTime.time
		}));
		src = src.slice(nextTimePos + nextTime.length);
		startTime = nextTime.time;
	}
	return createLine({ words });
}
/**
* 解析 ESLyric 逐词歌词格式字符串
* @param eslrc 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseEslrc(eslrc) {
	const result = [];
	for (const rawLine of eslrc.split(/\r?\n/)) {
		const line = parseEslrcLine(rawLine);
		if (line) result.push(line);
	}
	result.sort((a, b) => (a.words[0]?.startTime ?? Number.MAX_SAFE_INTEGER) - (b.words[0]?.startTime ?? Number.MAX_SAFE_INTEGER));
	for (const line of result) {
		for (const word of line.words) {
			word.startTime = clampTimestamp(word.startTime);
			word.endTime = clampTimestamp(word.endTime);
		}
		line.startTime = clampTimestamp(line.words[0]?.startTime ?? 0);
		line.endTime = clampTimestamp(line.words[line.words.length - 1]?.endTime ?? 0);
	}
	return result;
}
/**
* 将歌词数组转换为 ESLyric 逐词歌词格式字符串
* @param lines 歌词数组
* @returns ESLyric 逐词歌词格式字符串
*/
function stringifyEslrc(lines) {
	return lines.map((line) => {
		if (!line.words.length) return "";
		return `[${formatTime(clampTimestamp(line.words[0].startTime))}]${line.words.map((word) => `${word.word}[${formatTime(clampTimestamp(word.endTime))}]`).join("")}`;
	}).filter(Boolean).join("\n");
}
//#endregion
//#region src/formats/lys.ts
/**
* 解析 LYS 格式中的属性值
* @param prop 属性值
* @returns 对唱与背景标志位
*/
function parseProp(prop) {
	if (prop < 0 || prop > 8) prop = 0;
	return {
		isDuet: prop % 3 === 0 ? void 0 : prop % 3 === 2,
		isBG: prop <= 2 ? void 0 : prop >= 6
	};
}
/**
* 解析 LYS 格式的歌词字符串
* @param lys 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseLys(lys) {
	const lines = lys.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
	const lyricLines = [];
	const propRegex = /^\[(\d+)\]/;
	const wordRegex = /(.*?)\((\d+),(\d+)\)/g;
	for (const lineStr of lines) {
		const propMatch = lineStr.match(propRegex);
		if (!propMatch) continue;
		const [, propStr] = propMatch;
		const content = lineStr.slice(propMatch[0].length);
		const words = [];
		const props = parseProp(Number(propStr));
		for (const match of content.matchAll(wordRegex)) {
			const [, rawWord, startStr, durStr] = match;
			const startTime = Number(startStr);
			const endTime = startTime + Number(durStr);
			const wordText = rawWord;
			words.push(createWord({
				word: wordText,
				startTime,
				endTime
			}));
		}
		const lineStartTime = words[0]?.startTime ?? 0;
		const lineEndTime = words[words.length - 1]?.endTime ?? 0;
		if (!words.length) continue;
		if (props.isBG === void 0) props.isBG = words.length > 0 && /^[(（]/.test(words[0].word) && /[）)]$/.test(words[words.length - 1].word);
		if (props.isBG && words.length) {
			words[0].word = words[0].word.replace(/^[(（]/, "");
			words[words.length - 1].word = words[words.length - 1].word.replace(/[）)]$/, "");
		}
		lyricLines.push(createLine({
			startTime: lineStartTime,
			endTime: lineEndTime,
			isDuet: !!props.isDuet,
			isBG: props.isBG,
			words
		}));
	}
	return lyricLines;
}
function makeProp(line) {
	let prop = 0;
	prop += line.isDuet ? 2 : 1;
	prop += line.isBG ? 6 : 3;
	return prop;
}
/**
* 将歌词数组转换为 LYS 格式的字符串
* @param lines 歌词数组
* @returns LYS 格式的字符串
*/
function stringifyLys(lines) {
	return lines.map((line) => {
		const prop = makeProp(line);
		const printWords = [];
		line.words.forEach((w) => {
			if (w.word.trim() || !printWords.length) printWords.push({
				word: w.word,
				startTime: normalizeTimestamp(w.startTime),
				duration: normalizeDuration(normalizeTimestamp(w.endTime) - normalizeTimestamp(w.startTime))
			});
			else printWords[printWords.length - 1].word += w.word;
		});
		return `[${prop}]${printWords.map((w) => `${w.word}(${w.startTime},${w.duration})`).join("")}`;
	}).join("\n");
}
//#endregion
//#region src/formats/lqe.ts
function parseAttr(attr, headerMatches, rawLines, lines) {
	const headerIndex = headerMatches.findIndex((item) => {
		if (attr === "translatedLyric") return item.type === "translation";
		return item.type === "romanization";
	});
	if (headerIndex === -1) return;
	const timeRegex = /^\[((?:\d+:)*\d+(?:\.\d+)?)\](.*)$/;
	const attrLines = rawLines.slice(headerMatches[headerIndex].index + 1, headerMatches[headerIndex + 1].index).map((line) => line.trim()).filter((line) => line.length > 0).map((line) => {
		const match = line.match(timeRegex);
		if (!match) return null;
		const [, timeStr, text] = match;
		const time = parseTime(timeStr);
		if (Number.isNaN(time)) return null;
		return {
			time,
			text
		};
	}).filter((item) => item !== null);
	let attrLineIndex = 0;
	for (const line of lines) {
		if (attrLines[attrLineIndex]?.time !== line.startTime) continue;
		line[attr] = attrLines[attrLineIndex].text;
		attrLineIndex++;
	}
}
/**
* 解析 LQE 格式的歌词字符串
* @param lqe 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseLqe(lqe) {
	const lines = lqe.split(/\r?\n/).map((line) => line.trim()).filter((line) => line.length > 0);
	const headerRegex = /^\[([a-zA-Z]+):.+\]$/;
	const headerMatches = [];
	lines.forEach((line, index) => {
		const match = line.match(headerRegex);
		if (!match) return;
		const [, type] = match;
		if (type === "lyrics") headerMatches.push({
			index,
			type: "lyric"
		});
		else if (type === "translation") headerMatches.push({
			index,
			type: "translation"
		});
		else if (type === "pronunciation") headerMatches.push({
			index,
			type: "romanization"
		});
		else headerMatches.push({
			index,
			type: "unknown"
		});
	});
	headerMatches.push({
		index: lines.length,
		type: "unknown"
	});
	const lyricHeaderIndex = headerMatches.findIndex((item) => item.type === "lyric");
	if (lyricHeaderIndex === -1) return [];
	const parsedLines = parseLys(lines.slice(headerMatches[lyricHeaderIndex].index + 1, headerMatches[lyricHeaderIndex + 1].index).join("\n"));
	parseAttr("translatedLyric", headerMatches, lines, parsedLines);
	parseAttr("romanLyric", headerMatches, lines, parsedLines);
	return parsedLines;
}
function stringifyAttr(lines, attr) {
	const header = attr === "translatedLyric" ? "[translation: format@LRC]" : "[pronunciation: format@LRC, language@romaji]";
	const contentLines = lines.map((line) => {
		const value = line[attr];
		if (!value) return null;
		return `[${formatTime(line.startTime)}]${value}`;
	}).filter((line) => line !== null);
	if (contentLines.length === 0) return null;
	return [header, ...contentLines].join("\n");
}
/**
* 将歌词数组转换为 LQE 格式的字符串
* @param lines 歌词数组
* @returns LQE 格式的字符串
*/
function stringifyLqe(lines) {
	return ["[Lyricify Quick Export]\n[version:1.0]", [
		`[lyrics: format@Lyricify Syllable]\n${stringifyLys(lines)}`,
		stringifyAttr(lines, "translatedLyric"),
		stringifyAttr(lines, "romanLyric")
	].filter((section) => section !== null).join("\n\n\n")].join("\n\n");
}
//#endregion
//#region src/formats/lrc.ts
/**
* 解析 LyRiC 格式的歌词字符串
* @param lrc 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseLrc(lrc) {
	const tagRegex = /^\[([a-z]+):([^\]]+)\]$/;
	const timeRegex = /^\[((?:\d+:)*\d+(?:\.\d+)?)\](.*)$/;
	const bgRegex = /^[(（](.+)[)）]$/;
	const lines = lrc.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
	const lyricLines = [];
	for (let lineStr of lines) {
		if (tagRegex.test(lineStr)) continue;
		const timeStamps = [];
		while (true) {
			const match = lineStr.match(timeRegex);
			if (!match) break;
			const [, timeStr, text] = match;
			const timeStamp = parseTime(timeStr);
			if (Number.isNaN(timeStamp)) break;
			timeStamps.push(timeStamp);
			lineStr = text;
		}
		if (timeStamps.length === 0) continue;
		lineStr = lineStr.trim();
		const backgroundMatch = lineStr.match(bgRegex);
		const isBG = Boolean(backgroundMatch);
		if (backgroundMatch) lineStr = backgroundMatch[1];
		for (const t of timeStamps) lyricLines.push(createLine({
			startTime: t,
			endTime: MAX_LRC_TIMESTAMP,
			words: [createWord({
				word: lineStr,
				startTime: t,
				endTime: t
			})],
			isBG
		}));
	}
	lyricLines.sort((a, b) => a.startTime - b.startTime);
	for (const [prev, curr] of pairwise(lyricLines)) prev.endTime = prev.words[0].endTime = curr.startTime;
	return lyricLines.filter((line) => line.words[0].word);
}
/**
* 将歌词数组转换为 LyRiC 格式的字符串
* @param lines 歌词数组
* @returns LyRiC 格式的字符串
*/
function stringifyLrc(lines) {
	return lines.map((line) => {
		const text = line.words.map((w) => w.word).join("");
		const printText = line.isBG ? `(${text})` : text;
		return `[${formatTime(normalizeTimestamp(line.startTime))}]${printText}`;
	}).join("\n");
}
//#endregion
//#region src/formats/lrca2.ts
/**
* 解析 LRC A2 格式的歌词字符串
* @param lrc 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseLrcA2(lrc) {
	const lines = lrc.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
	const lyricLines = [];
	const lineTimeStampRegex = /^\[((?:\d+:)*\d+(?:\.\d+)?)\]/;
	const wordTimestampRegex = /<((?:\d+:)*\d+(?:\.\d+)?)>/;
	const wordTimestampPrefixRegex = /^<((?:\d+:)*\d+(?:\.\d+)?)>/;
	for (let lineStr of lines) {
		if (lineStr.match(/^\[([a-z]):(.+)\]$/i)) continue;
		const lineTimeStampmatch = lineStr.match(lineTimeStampRegex);
		if (!lineTimeStampmatch) continue;
		const [lineTimeStamp, lineTimeStr] = lineTimeStampmatch;
		const lineStartTime = parseTime(lineTimeStr);
		if (Number.isNaN(lineStartTime)) continue;
		lineStr = lineStr.slice(lineTimeStamp.length).trim();
		if (!lineStr) continue;
		const lineItems = [];
		while (lineStr.length) {
			const prefixedTimeStampMatch = lineStr.match(wordTimestampPrefixRegex);
			if (prefixedTimeStampMatch) {
				const [wordTimeStamp, wordTimeStr] = prefixedTimeStampMatch;
				const parsedWordTime = parseTime(wordTimeStr);
				if (!Number.isNaN(parsedWordTime)) lineItems.push(parsedWordTime);
				lineStr = lineStr.slice(wordTimeStamp.length);
				continue;
			}
			const nextWordTimeStampIndex = lineStr.search(wordTimestampRegex);
			const text = nextWordTimeStampIndex === -1 ? lineStr : lineStr.slice(0, nextWordTimeStampIndex);
			lineItems.push(text);
			lineStr = lineStr.slice(text.length);
		}
		const words = [];
		lineItems.forEach((item, index) => {
			if (typeof item === "number") return;
			const startTime = lineItems[index - 1] ?? lineStartTime;
			const endTime = lineItems[index + 1] ?? startTime;
			if (typeof startTime !== "number" || typeof endTime !== "number") return;
			if (item.startsWith(" ") && words[words.length - 1]?.word.trim()) words.push(createWord({ word: " " }));
			words.push(createWord({
				word: item.trim(),
				startTime,
				endTime
			}));
			if (item.endsWith(" ")) words.push(createWord({ word: " " }));
		});
		const lineEndTime = words[words.length - 1]?.endTime ?? lineStartTime;
		lyricLines.push(createLine({
			startTime: lineStartTime,
			endTime: lineEndTime,
			words
		}));
	}
	return lyricLines;
}
/**
* 将歌词数组转换为 LRC A2 格式的字符串
* @param lines 歌词数组
* @returns LRC A2 格式的字符串
*/
function stringifylrcA2(lines) {
	return lines.map((line) => {
		const normalizedLineStartTime = normalizeTimestamp(line.startTime);
		if (line.words.length === 0) return `[${formatTime(normalizedLineStartTime)}]`;
		const normalizedWords = [];
		line.words.forEach((w) => {
			if (!w.word.trim() && normalizedWords.length) {
				normalizedWords[normalizedWords.length - 1].word += w.word;
				return;
			}
			normalizedWords.push({
				word: w.word,
				startTime: normalizeTimestamp(w.startTime),
				endTime: normalizeTimestamp(w.endTime)
			});
		});
		const lineItems = normalizedWords.flatMap((w) => [w.startTime, w.word]);
		lineItems.push(normalizedWords[normalizedWords.length - 1].endTime);
		return `[${formatTime(normalizedLineStartTime)}]` + lineItems.map((item) => typeof item === "number" ? `<${formatTime(item)}>` : item).join("");
	}).join("\n");
}
//#endregion
//#region src/formats/lyl.ts
/**
* 解析 LYL 格式的歌词字符串
* @param lyl 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseLyl(lyl) {
	const lines = lyl.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
	const lyricLines = [];
	const timeRegex = /^\[(\d+),(\d+)\](.*)$/;
	const bgRegex = /^[(（](.+)[)）]$/;
	for (const lineStr of lines) {
		if (lineStr === "[type:LyricifyLines]") continue;
		const timeMatch = lineStr.match(timeRegex);
		if (!timeMatch) continue;
		const [, startStr, endStr, text] = timeMatch;
		const startTime = Number(startStr);
		const endTime = Number(endStr);
		const backgroundMatch = text.match(bgRegex);
		const isBG = Boolean(backgroundMatch);
		const textContent = (backgroundMatch ? backgroundMatch[1] : text).trim();
		if (!textContent) continue;
		lyricLines.push(createLine({
			startTime,
			endTime,
			isBG,
			words: [createWord({
				word: textContent,
				startTime,
				endTime
			})]
		}));
	}
	return lyricLines;
}
/**
* 将歌词数组转换为 LYL 格式的字符串
* @param lines 歌词数组
* @returns LYL 格式的字符串
*/
function stringifyLyl(lines) {
	return ["[type:LyricifyLines]", ...lines.map((line) => {
		const text = line.words.map((w) => w.word).join("");
		const printText = line.isBG ? `(${text})` : text;
		return `[${normalizeTimestamp(line.startTime)},${normalizeTimestamp(line.endTime)}]${printText}`;
	})].join("\n");
}
//#endregion
//#region src/formats/qrc.ts
/**
* 解析 QRC 格式的歌词字符串
* @param qrc 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseQrc(qrc) {
	const wordPattern = /(.*?)\((\d+),(\d+)\)/g;
	const linePattern = /^\[(\d+),(\d+)\]/;
	return qrc.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0).map((lineStr) => {
		const lineMatch = lineStr.match(linePattern);
		if (!lineMatch) return null;
		const [linePrefix, lineStartStr, lineDurStr] = lineMatch;
		const lineStart = Number(lineStartStr);
		const lineDuration = Number(lineDurStr);
		const words = [];
		const lineContent = lineStr.slice(linePrefix.length).trim();
		if (!lineContent) return null;
		for (const wordMatch of lineContent.matchAll(wordPattern)) {
			const [, wordText, wordStartStr, wordDurStr] = wordMatch;
			const wordStart = Number(wordStartStr);
			const wordDur = Number(wordDurStr);
			words.push(createWord({
				word: wordText,
				startTime: wordStart,
				endTime: wordStart + wordDur
			}));
		}
		const isBG = words.length > 0 && /^[(（]/.test(words[0].word) && /[）)]$/.test(words[words.length - 1].word);
		if (isBG) {
			words[0].word = words[0].word.replace(/^[(（]/, "");
			words[words.length - 1].word = words[words.length - 1].word.replace(/[）)]$/, "");
		}
		return createLine({
			startTime: lineStart,
			endTime: lineStart + lineDuration,
			words,
			isBG
		});
	}).filter((line) => line !== null);
}
/**
* 将歌词数组转换为 QRC 格式的字符串
* @param lines 歌词数组
* @returns QRC 格式的字符串
*/
function stringifyQrc(lines) {
	return lines.map((line) => {
		const lineStart = normalizeTimestamp(line.startTime);
		const lineDuration = normalizeDuration(normalizeTimestamp(line.endTime) - lineStart);
		const lineWords = [];
		for (const [index, { word, startTime, endTime }] of line.words.entries()) {
			if (!word.trim() && lineWords.length) {
				lineWords[lineWords.length - 1] += word;
				continue;
			}
			let printedWord = word;
			if (line.isBG) {
				if (index === 0) printedWord = `（${printedWord}`;
				if (index === line.words.length - 1) printedWord += "）";
			}
			const normalizedWordStart = normalizeTimestamp(startTime);
			const wordDuration = normalizeDuration(normalizeTimestamp(endTime) - normalizedWordStart);
			lineWords.push(`${printedWord}(${normalizedWordStart},${wordDuration})`);
		}
		return `[${lineStart},${lineDuration}]${lineWords.join("")}`;
	}).join("\n");
}
//#endregion
//#region src/formats/yrc.ts
const beginParenPattern = /^[（(]/;
const endParenPattern = /[）)]$/;
function checkIsBG(words) {
	return words.length > 0 && beginParenPattern.test(words[0].word) && endParenPattern.test(words[words.length - 1].word);
}
function trimBGParentheses(words) {
	words[0].word = words[0].word.slice(1);
	words[words.length - 1].word = words[words.length - 1].word.slice(0, -1);
}
/**
* 解析 YRC 格式的歌词字符串
* @param yrc 歌词字符串
* @returns 成功解析出来的歌词
*/
function parseYrc(yrc) {
	const wordPattern = /^(.*?)\((\d+),(\d+),0\)/;
	const linePattern = /^\[(\d+),(\d+)\]/;
	return yrc.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0).map((lineStr) => {
		const lineMatch = lineStr.match(linePattern);
		if (!lineMatch) return null;
		const [linePrefix, lineStartStr, lineDurStr] = lineMatch;
		const lineStart = Number(lineStartStr);
		const lineDuration = Number(lineDurStr);
		const words = [];
		let lineContent = lineStr.slice(linePrefix.length).trim();
		if (!lineContent) return null;
		let lastStart = -1;
		let lastEnd = -1;
		while (true) {
			const wordMatch = lineContent.match(wordPattern);
			if (!wordMatch) break;
			const [fullMatch, lastText, wordStartStr, wordDurStr] = wordMatch;
			if (lastText && lastStart !== -1) words.push(createWord({
				word: lastText,
				startTime: lastStart,
				endTime: lastEnd
			}));
			const wordStart = Number(wordStartStr);
			const wordEnd = wordStart + Number(wordDurStr);
			[lastStart, lastEnd] = [wordStart, wordEnd];
			lineContent = lineContent.slice(fullMatch.length);
		}
		if (lastStart !== -1 && lineContent) words.push(createWord({
			word: lineContent,
			startTime: lastStart,
			endTime: lastEnd
		}));
		const isBG = checkIsBG(words);
		if (isBG) trimBGParentheses(words);
		return createLine({
			startTime: lineStart,
			endTime: lineStart + lineDuration,
			words,
			isBG
		});
	}).filter((line) => line !== null);
}
function makeParenthesesFull(text) {
	return text.replace(/\(/g, "（").replace(/\)/g, "）");
}
/**
* 将歌词数组转换为 YRC 格式的字符串
* @param lines 歌词数组
* @returns YRC 格式的字符串
*/
function stringifyYrc(lines) {
	return lines.map((line) => {
		const lineStart = normalizeTimestamp(line.startTime);
		const lineDuration = normalizeDuration(normalizeTimestamp(line.endTime) - lineStart);
		const lineWords = [];
		for (const [index, { word, startTime, endTime }] of line.words.entries()) {
			if (!word.trim() && lineWords.length) {
				lineWords[lineWords.length - 1] += word;
				continue;
			}
			let printedWord = makeParenthesesFull(word);
			if (line.isBG) {
				if (index === 0) printedWord = `（${printedWord}`;
				if (index === line.words.length - 1) printedWord += "）";
			}
			const normalizedWordStart = normalizeTimestamp(startTime);
			const wordDuration = normalizeDuration(normalizeTimestamp(endTime) - normalizedWordStart);
			lineWords.push(`(${normalizedWordStart},${wordDuration},0)${printedWord}`);
		}
		return `[${lineStart},${lineDuration}]${lineWords.join("")}`;
	}).join("\n");
}
//#endregion
//#region src/myplayer-app.ts
const TTML_NS = "http://www.w3.org/ns/ttml";
const ROLE_ATTR_NAMES = ["role", "ttm:role"];
const PREFERRED_TRANSLATION_LANGUAGES = [
	"zh-Hans",
	"zh-Hans-CN",
	"zh-CN",
	"zh",
	"cmn-Hans"
];
function parseTimeMs(value) {
	if (!value) return 0;
	const parts = value.trim().split(":");
	const secondsText = parts.pop();
	if (!secondsText) return 0;
	const seconds = Number(secondsText);
	const minutes = parts.length > 0 ? Number(parts.pop()) : 0;
	const hours = parts.length > 0 ? Number(parts.pop()) : 0;
	if (![
		seconds,
		minutes,
		hours
	].every(Number.isFinite)) return 0;
	return Math.round(((hours * 60 + minutes) * 60 + seconds) * 1e3);
}
function getLocalName(element) {
	return (element.localName || element.tagName || "").toLowerCase().split(":").pop() || "";
}
function getRole(element) {
	for (const attr of ROLE_ATTR_NAMES) {
		const value = element.getAttribute(attr);
		if (value) return value.toLowerCase();
	}
	return "";
}
function getText(element) {
	return (element.textContent || "").replace(/\s+/g, " ").trim();
}
function getPElements(doc) {
	const namespaced = Array.from(doc.getElementsByTagNameNS(TTML_NS, "p"));
	if (namespaced.length > 0) return namespaced;
	return Array.from(doc.getElementsByTagName("p"));
}
function getDirectSpans(element) {
	return Array.from(element.childNodes).filter((node) => node.nodeType === 1 && getLocalName(node) === "span");
}
function collectTranslationLanguages(result) {
	const languages = [];
	const pushFrom = (items) => {
		if (!items) return;
		for (const item of items) if (item.language) languages.push(item.language);
	};
	for (const line of result.lines) {
		pushFrom(line.translations);
		pushFrom(line.backgroundVocal?.translations);
	}
	return languages;
}
function resolvePreferredTranslationLanguage(result) {
	const languages = collectTranslationLanguages(result);
	for (const preferred of PREFERRED_TRANSLATION_LANGUAGES) {
		const exact = languages.find((language) => language === preferred);
		if (exact) return exact;
	}
	return languages.find((language) => language.toLowerCase().startsWith("zh"));
}
function parseUpstreamTTMLForApp(ttmlText) {
	const result = TTMLParser.parse(ttmlText);
	const translationLanguage = resolvePreferredTranslationLanguage(result);
	return toAmllLyrics(result, translationLanguage ? { translationLanguage } : void 0);
}
function parseLegacyPlainTTML(ttmlText) {
	if (typeof DOMParser === "undefined") return {
		lines: [],
		metadata: []
	};
	const doc = new DOMParser().parseFromString(ttmlText, "application/xml");
	if (doc.getElementsByTagName("parsererror")[0]) return {
		lines: [],
		metadata: []
	};
	const lines = [];
	for (const p of getPElements(doc)) {
		const startTime = parseTimeMs(p.getAttribute("begin"));
		const endTime = parseTimeMs(p.getAttribute("end"));
		const text = getText(p);
		if (!text || startTime === 0 && endTime === 0) continue;
		let translatedLyric = "";
		let romanLyric = "";
		const words = [];
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
			if (wordStart > 0 || wordEnd > 0) words.push({
				startTime: wordStart,
				endTime: wordEnd,
				word: spanText,
				romanWord: ""
			});
		}
		lines.push({
			words: words.length > 0 ? words : [{
				startTime: 0,
				endTime: 0,
				word: text,
				romanWord: ""
			}],
			translatedLyric,
			romanLyric,
			isBG: false,
			isDuet: false,
			startTime,
			endTime
		});
	}
	return {
		lines,
		metadata: []
	};
}
function parseTTML(ttmlText) {
	const result = parseUpstreamTTMLForApp(ttmlText);
	if (result.lines.length > 0) return result;
	const fallback = parseLegacyPlainTTML(ttmlText);
	return fallback.lines.length > 0 ? fallback : result;
}
//#endregion
export { decryptQrcHex, encryptQrcHex, parseEslrc, parseLqe, parseLrc, parseLrcA2, parseLyl, parseLys, parseQrc, parseTTML, parseYrc, stringifyAss, stringifyEslrc, stringifyLqe, stringifyLrc, stringifyLyl, stringifyLys, stringifyQrc, stringifyTTML, stringifyYrc, stringifylrcA2 };

//# sourceMappingURL=amll-lyric.mjs.map