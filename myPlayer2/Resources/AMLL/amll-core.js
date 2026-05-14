//#region ../../node_modules/.pnpm/@ungap+structured-clone@1.3.1/node_modules/@ungap/structured-clone/esm/deserialize.js
const env = typeof self === "object" ? self : globalThis;
const guard = (name, init) => {
	switch (name) {
		case "Function":
		case "SharedWorker":
		case "Worker":
		case "eval":
		case "setInterval":
		case "setTimeout": throw new TypeError("unable to deserialize " + name);
	}
	return new env[name](init);
};
const deserializer = ($, _) => {
	const as = (out, index) => {
		$.set(index, out);
		return out;
	};
	const unpair = (index) => {
		if ($.has(index)) return $.get(index);
		const [type, value] = _[index];
		switch (type) {
			case 0:
			case -1: return as(value, index);
			case 1: {
				const arr = as([], index);
				for (const index of value) arr.push(unpair(index));
				return arr;
			}
			case 2: {
				const object = as({}, index);
				for (const [key, index] of value) object[unpair(key)] = unpair(index);
				return object;
			}
			case 3: return as(new Date(value), index);
			case 4: {
				const { source, flags } = value;
				return as(new RegExp(source, flags), index);
			}
			case 5: {
				const map = as(/* @__PURE__ */ new Map(), index);
				for (const [key, index] of value) map.set(unpair(key), unpair(index));
				return map;
			}
			case 6: {
				const set = as(/* @__PURE__ */ new Set(), index);
				for (const index of value) set.add(unpair(index));
				return set;
			}
			case 7: {
				const { name, message } = value;
				return as(guard(name, message), index);
			}
			case 8: return as(BigInt(value), index);
			case "BigInt": return as(Object(BigInt(value)), index);
			case "ArrayBuffer": return as(new Uint8Array(value).buffer, value);
			case "DataView": {
				const { buffer } = new Uint8Array(value);
				return as(new DataView(buffer), value);
			}
		}
		return as(guard(type, value), index);
	};
	return unpair;
};
/**
* @typedef {Array<string,any>} Record a type representation
*/
/**
* Returns a deserialized value from a serialized array of Records.
* @param {Record[]} serialized a previously serialized value.
* @returns {any}
*/
const deserialize = (serialized) => deserializer(/* @__PURE__ */ new Map(), serialized)(0);
//#endregion
//#region ../../node_modules/.pnpm/@ungap+structured-clone@1.3.1/node_modules/@ungap/structured-clone/esm/serialize.js
const EMPTY = "";
const { toString } = {};
const { keys } = Object;
const typeOf = (value) => {
	const type = typeof value;
	if (type !== "object" || !value) return [0, type];
	const asString = toString.call(value).slice(8, -1);
	switch (asString) {
		case "Array": return [1, EMPTY];
		case "Object": return [2, EMPTY];
		case "Date": return [3, EMPTY];
		case "RegExp": return [4, EMPTY];
		case "Map": return [5, EMPTY];
		case "Set": return [6, EMPTY];
		case "DataView": return [1, asString];
	}
	if (asString.includes("Array")) return [1, asString];
	if (asString.includes("Error")) return [7, asString];
	return [2, asString];
};
const shouldSkip = ([TYPE, type]) => TYPE === 0 && (type === "function" || type === "symbol");
const serializer = (strict, json, $, _) => {
	const as = (out, value) => {
		const index = _.push(out) - 1;
		$.set(value, index);
		return index;
	};
	const pair = (value) => {
		if ($.has(value)) return $.get(value);
		let [TYPE, type] = typeOf(value);
		switch (TYPE) {
			case 0: {
				let entry = value;
				switch (type) {
					case "bigint":
						TYPE = 8;
						entry = value.toString();
						break;
					case "function":
					case "symbol":
						if (strict) throw new TypeError("unable to serialize " + type);
						entry = null;
						break;
					case "undefined": return as([-1], value);
				}
				return as([TYPE, entry], value);
			}
			case 1: {
				if (type) {
					let spread = value;
					if (type === "DataView") spread = new Uint8Array(value.buffer);
					else if (type === "ArrayBuffer") spread = new Uint8Array(value);
					return as([type, [...spread]], value);
				}
				const arr = [];
				const index = as([TYPE, arr], value);
				for (const entry of value) arr.push(pair(entry));
				return index;
			}
			case 2: {
				if (type) switch (type) {
					case "BigInt": return as([type, value.toString()], value);
					case "Boolean":
					case "Number":
					case "String": return as([type, value.valueOf()], value);
				}
				if (json && "toJSON" in value) return pair(value.toJSON());
				const entries = [];
				const index = as([TYPE, entries], value);
				for (const key of keys(value)) if (strict || !shouldSkip(typeOf(value[key]))) entries.push([pair(key), pair(value[key])]);
				return index;
			}
			case 3: return as([TYPE, value.toISOString()], value);
			case 4: {
				const { source, flags } = value;
				return as([TYPE, {
					source,
					flags
				}], value);
			}
			case 5: {
				const entries = [];
				const index = as([TYPE, entries], value);
				for (const [key, entry] of value) if (strict || !(shouldSkip(typeOf(key)) || shouldSkip(typeOf(entry)))) entries.push([pair(key), pair(entry)]);
				return index;
			}
			case 6: {
				const entries = [];
				const index = as([TYPE, entries], value);
				for (const entry of value) if (strict || !shouldSkip(typeOf(entry))) entries.push(pair(entry));
				return index;
			}
		}
		const { message } = value;
		return as([TYPE, {
			name: type,
			message
		}], value);
	};
	return pair;
};
/**
* @typedef {Array<string,any>} Record a type representation
*/
/**
* Returns an array of serialized Records.
* @param {any} value a serializable value.
* @param {{json?: boolean, lossy?: boolean}?} options an object with a `lossy` or `json` property that,
*  if `true`, will not throw errors on incompatible types, and behave more
*  like JSON stringify would behave. Symbol and Function will be discarded.
* @returns {Record[]}
*/
const serialize = (value, { json, lossy } = {}) => {
	const _ = [];
	return serializer(!(json || lossy), !!json, /* @__PURE__ */ new Map(), _)(value), _;
};
//#endregion
//#region ../../node_modules/.pnpm/@ungap+structured-clone@1.3.1/node_modules/@ungap/structured-clone/esm/index.js
/**
* @typedef {Array<string,any>} Record a type representation
*/
/**
* Returns an array of serialized Records.
* @param {any} any a serializable value.
* @param {{transfer?: any[], json?: boolean, lossy?: boolean}?} options an object with
* a transfer option (ignored when polyfilled) and/or non standard fields that
* fallback to the polyfill if present.
* @returns {Record[]}
*/
var esm_default = typeof structuredClone === "function" ? (any, options) => options && ("json" in options || "lossy" in options) ? deserialize(serialize(any, options)) : structuredClone(any) : (any, options) => deserialize(serialize(any, options));
//#endregion
//#region src/styles/lyric-player.module.css
var lyric_player_module_default = {
	"active": "xkZOxW_active",
	"bottomLine": "xkZOxW_bottomLine",
	"dirty": "xkZOxW_dirty",
	"disableSpring": "xkZOxW_disableSpring",
	"duet": "xkZOxW_duet",
	"emphasize": "xkZOxW_emphasize",
	"emphasizeWrapper": "xkZOxW_emphasizeWrapper",
	"enabled": "xkZOxW_enabled",
	"hasDuetLine": "xkZOxW_hasDuetLine",
	"interludeDots": "xkZOxW_interludeDots",
	"lyricBgLine": "xkZOxW_lyricBgLine",
	"lyricDuetLine": "xkZOxW_lyricDuetLine",
	"lyricLine": "xkZOxW_lyricLine",
	"lyricMainLine": "xkZOxW_lyricMainLine",
	"lyricSubLine": "xkZOxW_lyricSubLine",
	"romanWord": "xkZOxW_romanWord",
	"rubyWord": "xkZOxW_rubyWord",
	"tmpDisableTransition": "xkZOxW_tmpDisableTransition",
	"wordBody": "xkZOxW_wordBody",
	"wordWithRuby": "xkZOxW_wordWithRuby"
};
//#endregion
//#region src/utils/optimize-lyric.ts
const DEFAULT_OPTIMIZE_OPTIONS = {
	normalizeSpaces: true,
	resetLineTimestamps: true,
	convertExcessiveBackgroundLines: true,
	syncMainAndBackgroundLines: true,
	cleanUnintentionalOverlaps: true,
	tryAdvanceStartTime: true
};
/**
* 规范化歌词中的空格，将多个连续空格替换为一个空格
*/
function normalizeSpaces(lines) {
	for (const line of lines) for (const word of line.words) word.word = word.word.replace(/\s+/g, " ");
}
/**
* 将行级时间戳强行设为字级时间戳
*/
function resetLineTimestamps(lines) {
	for (const line of lines) if (line.words.length === 1 && line.words[0].startTime === 0 && line.words[0].endTime === 0 && (line.startTime !== 0 || line.endTime !== 0)) {
		line.words[0].startTime = line.startTime;
		line.words[0].endTime = line.endTime;
	} else if (line.words.length > 0) {
		const firstWord = line.words[0];
		const lastWord = line.words[line.words.length - 1];
		line.startTime = firstWord.startTime;
		line.endTime = lastWord.endTime;
	}
}
/**
* 把多行背景人声转换为单行背景人声 + 主歌词行的形式
*/
function convertExcessiveBackgroundLines(lines) {
	let consecutiveBgCount = 0;
	for (const line of lines) if (line.isBG) {
		consecutiveBgCount++;
		if (consecutiveBgCount > 1) line.isBG = false;
	} else consecutiveBgCount = 0;
}
/**
* 同步主歌词与背景人声的时间
*
* 取两者中最早的开始时间和最晚的结束时间，应用给双方
*/
function syncMainAndBackgroundLines(lines) {
	for (let i = lines.length - 1; i >= 0; i--) {
		const line = lines[i];
		if (line.isBG) continue;
		const nextLine = lines[i + 1];
		if (nextLine?.isBG) {
			const allWords = [...line.words, ...nextLine.words].filter((w) => w.word.trim().length > 0);
			if (allWords.length > 0) {
				const minStart = Math.min(...allWords.map((w) => w.startTime));
				const maxEnd = Math.max(...allWords.map((w) => w.endTime));
				const finalStart = Math.min(minStart, line.startTime, nextLine.startTime);
				const finalEnd = Math.max(maxEnd, line.endTime, nextLine.endTime);
				line.startTime = finalStart;
				line.endTime = finalEnd;
				nextLine.startTime = finalStart;
				nextLine.endTime = finalEnd;
			}
		}
	}
}
/**
* 清洗非刻意的重叠
*
* 如果重叠大于100ms 且 重叠超过下一行时长的10%，则视为刻意重叠，否则将结束时间设为下一行的开始时间
*/
function cleanUnintentionalOverlaps(lines) {
	for (let i = 0; i < lines.length - 1; i++) {
		const line = lines[i];
		if (line.isBG) continue;
		let nextMainIndex = i + 1;
		while (nextMainIndex < lines.length && lines[nextMainIndex].isBG) nextMainIndex++;
		if (nextMainIndex < lines.length) {
			const nextLine = lines[nextMainIndex];
			const overlap = line.endTime - nextLine.startTime;
			if (overlap > 0) {
				const percentageThreshold = (nextLine.endTime - nextLine.startTime) * .1;
				if (!(overlap > 100 && overlap > percentageThreshold)) {
					line.endTime = nextLine.startTime;
					const attachedBgLine = lines[i + 1];
					if (attachedBgLine?.isBG) attachedBgLine.endTime = nextLine.startTime;
				}
			}
		}
	}
}
/**
* 尝试让歌词提前最多 600ms 开始，如果有重叠则尝试最多提前 400ms 或上一行时长的 30%
*/
function tryAdvanceStartTime(lines) {
	const defaultAdvanceAmount = 600;
	const fallbackAdvanceAmount = 400;
	const fallbackAdvanceRatio = .3;
	let prevLineStartTime = 0;
	let prevLineEndTime = 0;
	let prevMainGroupStartTime = 0;
	let prevMainGroupEndTime = 0;
	let hasPrevLine = false;
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		if (line.isBG) continue;
		const originalStartTime = line.startTime;
		const originalEndTime = line.endTime;
		let targetAdvanceAmount = 0;
		let safeBoundary = 0;
		if (hasPrevLine) if (originalStartTime >= prevLineEndTime) {
			targetAdvanceAmount = defaultAdvanceAmount;
			safeBoundary = prevMainGroupEndTime;
		} else {
			targetAdvanceAmount = fallbackAdvanceAmount;
			const prevDuration = prevLineEndTime - prevLineStartTime;
			safeBoundary = prevLineStartTime + prevDuration * fallbackAdvanceRatio;
		}
		else {
			targetAdvanceAmount = defaultAdvanceAmount;
			safeBoundary = 0;
		}
		const targetTime = line.startTime - targetAdvanceAmount;
		const newStartTime = Math.max(safeBoundary, targetTime);
		if (newStartTime < line.startTime) line.startTime = newStartTime;
		const nextLine = lines[i + 1];
		if (nextLine?.isBG) nextLine.startTime = line.startTime;
		if (hasPrevLine) if (originalStartTime < prevMainGroupEndTime && originalEndTime > prevMainGroupStartTime) {
			prevMainGroupStartTime = Math.min(prevMainGroupStartTime, originalStartTime);
			prevMainGroupEndTime = Math.max(prevMainGroupEndTime, originalEndTime);
		} else {
			prevMainGroupStartTime = originalStartTime;
			prevMainGroupEndTime = originalEndTime;
		}
		else {
			prevMainGroupStartTime = originalStartTime;
			prevMainGroupEndTime = originalEndTime;
		}
		prevLineStartTime = originalStartTime;
		prevLineEndTime = originalEndTime;
		hasPrevLine = true;
	}
}
/**
* 优化歌词行的展示效果
*
* 注意会直接原地修改入参，确保你已经提前深克隆了歌词行数组
* @param lines 歌词行数组
* @param options 优化的可选配置，默认全部开启
*/
function optimizeLyricLines(lines, options) {
	const config = {
		...DEFAULT_OPTIMIZE_OPTIONS,
		...options
	};
	if (config.normalizeSpaces) normalizeSpaces(lines);
	if (config.resetLineTimestamps) resetLineTimestamps(lines);
	if (config.convertExcessiveBackgroundLines) convertExcessiveBackgroundLines(lines);
	if (config.syncMainAndBackgroundLines) syncMainAndBackgroundLines(lines);
	if (config.cleanUnintentionalOverlaps) cleanUnintentionalOverlaps(lines);
	if (config.tryAdvanceStartTime) tryAdvanceStartTime(lines);
}
//#endregion
//#region src/utils/clamp.ts
function clamp(x, min, max) {
	return Math.min(Math.max(x, min), max);
}
function clamp01(x) {
	return clamp(x, 0, 1);
}
function clampPositive(x) {
	return Math.max(0, x);
}
//#endregion
//#region src/lyric-player/dom/interlude-dots.ts
function easeInOutBack(x) {
	const c2 = 1.70158 * 1.525;
	return x < .5 ? (2 * x) ** 2 * ((c2 + 1) * 2 * x - c2) / 2 : ((2 * x - 2) ** 2 * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2;
}
function easeOutExpo(x) {
	return x === 1 ? 1 : 1 - 2 ** (-10 * x);
}
var InterludeDots = class {
	element = document.createElement("div");
	dot0 = document.createElement("span");
	dot1 = document.createElement("span");
	dot2 = document.createElement("span");
	left = 0;
	top = 0;
	playing = true;
	lastStyle = "";
	currentInterlude;
	currentTime = 0;
	targetBreatheDuration = 1500;
	constructor() {
		this.element.className = lyric_player_module_default.interludeDots;
		this.element.appendChild(this.dot0);
		this.element.appendChild(this.dot1);
		this.element.appendChild(this.dot2);
	}
	getElement() {
		return this.element;
	}
	setTransform(left = this.left, top = this.top) {
		this.left = left;
		this.top = top;
		this.update();
	}
	setInterlude(interlude) {
		this.currentInterlude = interlude;
		this.currentTime = interlude?.[0] ?? 0;
		if (interlude) this.element.classList.add(lyric_player_module_default.enabled);
		else this.element.classList.remove(lyric_player_module_default.enabled);
	}
	pause() {
		this.playing = false;
		this.element.classList.remove(lyric_player_module_default.playing);
	}
	resume() {
		this.playing = true;
		this.element.classList.add(lyric_player_module_default.playing);
	}
	update(delta = 0) {
		if (!this.playing) return;
		this.currentTime += delta;
		let curStyle = "";
		curStyle += `transform:translate(${this.left.toFixed(2)}px, ${this.top.toFixed(2)}px)`;
		if (this.currentInterlude) {
			const interludeDuration = this.currentInterlude[1] - this.currentInterlude[0];
			const currentDuration = this.currentTime - this.currentInterlude[0];
			if (currentDuration <= interludeDuration) {
				const breatheDuration = interludeDuration / Math.ceil(interludeDuration / this.targetBreatheDuration);
				let scale = 1;
				let globalOpacity = 1;
				scale *= Math.sin(1.5 * Math.PI - currentDuration / breatheDuration * 2) / 20 + 1;
				if (currentDuration < 2e3) scale *= easeOutExpo(currentDuration / 2e3);
				if (currentDuration < 500) globalOpacity = 0;
				else if (currentDuration < 1e3) globalOpacity *= (currentDuration - 500) / 500;
				if (interludeDuration - currentDuration < 750) scale *= 1 - easeInOutBack((750 - (interludeDuration - currentDuration)) / 750 / 2);
				if (interludeDuration - currentDuration < 375) globalOpacity *= clamp01((interludeDuration - currentDuration) / 375);
				const dotsDuration = clampPositive(interludeDuration - 750);
				scale = clampPositive(scale) * .7;
				curStyle += ` scale(${scale})`;
				const dot0Opacity = clamp(.25, currentDuration * 3 / dotsDuration * .75, 1);
				const dot1Opacity = clamp(.25, (currentDuration - dotsDuration / 3) * 3 / dotsDuration * .75, 1);
				const dot2Opacity = clamp(.25, (currentDuration - dotsDuration / 3 * 2) * 3 / dotsDuration * .75, 1);
				this.dot0.style.opacity = `${clamp01(globalOpacity * dot0Opacity)}`;
				this.dot1.style.opacity = `${clamp01(globalOpacity * dot1Opacity)}`;
				this.dot2.style.opacity = `${clamp01(globalOpacity * dot2Opacity)}`;
			} else {
				curStyle += " scale(0)";
				this.dot0.style.opacity = "0";
				this.dot1.style.opacity = "0";
				this.dot2.style.opacity = "0";
			}
			curStyle += ";";
			if (this.lastStyle !== curStyle) {
				this.element.setAttribute("style", curStyle);
				this.lastStyle = curStyle;
			}
		}
	}
	dispose() {
		this.element.remove();
	}
};
//#endregion
//#region src/utils/schedule.ts
const measureTasks = [];
const mutateTasks = [];
let scheduled = false;
function onFlush() {
	let tmp = mutateTasks.shift();
	while (tmp) {
		try {
			tmp.resolve(tmp.task());
		} catch (error) {
			tmp.reject(error);
		}
		tmp = mutateTasks.shift();
	}
	tmp = measureTasks.shift();
	while (tmp) {
		try {
			tmp.resolve(tmp.task());
		} catch (error) {
			tmp.reject(error);
		}
		tmp = measureTasks.shift();
	}
	scheduled = false;
}
function scheduleFlush() {
	if (!scheduled) {
		scheduled = true;
		requestAnimationFrame(onFlush);
	}
}
function measure(callback) {
	const task = {
		task: callback,
		resolve: () => {},
		reject: () => {}
	};
	const promise = new Promise((resolve, reject) => {
		task.resolve = resolve;
		task.reject = reject;
	});
	measureTasks.push(task);
	scheduleFlush();
	return promise;
}
//#endregion
//#region src/utils/derivative.ts
function derivative(f) {
	const h = .001;
	return (x) => (f(x + h) - f(x - h)) / (2 * h);
}
function getVelocity(f) {
	return derivative(f);
}
//#endregion
//#region src/utils/spring.ts
var Spring = class {
	currentPosition = 0;
	targetPosition = 0;
	currentTime = 0;
	params = {};
	currentSolver;
	getV;
	getV2;
	queueParams;
	queuePosition;
	constructor(currentPosition = 0) {
		this.targetPosition = currentPosition;
		this.currentPosition = this.targetPosition;
		this.currentSolver = () => this.targetPosition;
		this.getV = () => 0;
		this.getV2 = () => 0;
	}
	resetSolver() {
		const curV = this.getV(this.currentTime);
		this.currentTime = 0;
		this.currentSolver = solveSpring(this.currentPosition, curV, this.targetPosition, 0, this.params);
		this.getV = getVelocity(this.currentSolver);
		this.getV2 = getVelocity(this.getV);
	}
	arrived() {
		return Math.abs(this.targetPosition - this.currentPosition) < .01 && this.getV(this.currentTime) < .01 && this.getV2(this.currentTime) < .01 && this.queueParams === void 0 && this.queuePosition === void 0;
	}
	setPosition(targetPosition) {
		this.targetPosition = targetPosition;
		this.currentPosition = targetPosition;
		this.currentSolver = () => this.targetPosition;
		this.getV = () => 0;
		this.getV2 = () => 0;
	}
	update(delta = 0) {
		this.currentTime += delta;
		this.currentPosition = this.currentSolver(this.currentTime);
		if (this.queueParams) {
			this.queueParams.time -= delta;
			if (this.queueParams.time <= 0) this.updateParams({ ...this.queueParams });
		}
		if (this.queuePosition) {
			this.queuePosition.time -= delta;
			if (this.queuePosition.time <= 0) this.setTargetPosition(this.queuePosition.position);
		}
		if (this.arrived()) this.setPosition(this.targetPosition);
	}
	updateParams(params, delay = 0) {
		if (delay > 0) this.queueParams = {
			...this.queuePosition ?? {},
			...params,
			time: delay
		};
		else {
			this.queuePosition = void 0;
			this.params = {
				...this.params,
				...params
			};
			this.resetSolver();
		}
	}
	setTargetPosition(targetPosition, delay = 0) {
		if (delay > 0) this.queuePosition = {
			...this.queuePosition ?? {},
			position: targetPosition,
			time: delay
		};
		else {
			this.queuePosition = void 0;
			this.targetPosition = targetPosition;
			this.resetSolver();
		}
	}
	getCurrentPosition() {
		return this.currentPosition;
	}
};
function solveSpring(from, velocity, to, delay = 0, params) {
	const soft = params?.soft ?? false;
	const stiffness = params?.stiffness ?? 100;
	const damping = params?.damping ?? 10;
	const mass = params?.mass ?? 1;
	const delta = to - from;
	if (soft || 1 <= damping / (2 * Math.sqrt(stiffness * mass))) {
		const angular_frequency = -Math.sqrt(stiffness / mass);
		const leftover = -angular_frequency * delta - velocity;
		return (t) => {
			t -= delay;
			if (t < 0) return from;
			return to - (delta + t * leftover) * Math.E ** (t * angular_frequency);
		};
	}
	const damping_frequency = Math.sqrt(4 * mass * stiffness - damping ** 2);
	const leftover = (damping * delta - 2 * mass * velocity) / damping_frequency;
	const dfm = .5 * damping_frequency / mass;
	const dm = -(.5 * damping) / mass;
	return (t) => {
		t -= delay;
		if (t < 0) return from;
		return to - (Math.cos(t * dfm) * delta + Math.sin(t * dfm) * leftover) * Math.E ** (t * dm);
	};
}
//#endregion
//#region src/lyric-player/base/bottom-line.ts
var BottomLineEl = class {
	element = document.createElement("div");
	left = 0;
	top = 0;
	delay = 0;
	lineSize = [0, 0];
	lineTransforms = {
		posX: new Spring(0),
		posY: new Spring(0)
	};
	isFocused = false;
	blur = 0;
	constructor(lyricPlayer) {
		this.lyricPlayer = lyricPlayer;
		this.element.setAttribute("class", `${lyric_player_module_default.lyricLine} ${lyric_player_module_default.bottomLine}`);
		this.element.dataset.bottomLine = "true";
		this.rebuildStyle();
	}
	async measureSize() {
		return await measure(() => [this.element.clientWidth, this.element.clientHeight]);
	}
	lastStyle = "";
	show() {
		this.rebuildStyle();
	}
	hide() {
		this.rebuildStyle();
	}
	setFocused(focused) {
		if (this.isFocused !== focused) {
			this.isFocused = focused;
			if (focused) this.element.dataset.focused = "true";
			else delete this.element.dataset.focused;
		}
	}
	rebuildStyle() {
		let style = `transform:translate(${this.lineTransforms.posX.getCurrentPosition().toFixed(2)}px,${this.lineTransforms.posY.getCurrentPosition().toFixed(2)}px);`;
		if (!this.lyricPlayer.getEnableSpring() && this.isInSight) style += `transition-delay:${this.delay}ms;`;
		style += `filter:blur(${Math.min(5, this.blur)}px);`;
		if (style !== this.lastStyle) {
			this.lastStyle = style;
			this.element.setAttribute("style", style);
		}
	}
	getElement() {
		return this.element;
	}
	setTransform(left = this.left, top = this.top, blur = 0, force = false, delay = 0) {
		this.left = left;
		this.top = top;
		this.delay = delay * 1e3 | 0;
		if (force || !this.lyricPlayer.getEnableSpring()) {
			this.blur = Math.min(32, blur);
			if (force) this.element.classList.add(lyric_player_module_default.tmpDisableTransition);
			this.lineTransforms.posX.setPosition(left);
			this.lineTransforms.posY.setPosition(top);
			if (!this.lyricPlayer.getEnableSpring()) this.show();
			else this.rebuildStyle();
			if (force) requestAnimationFrame(() => {
				this.element.classList.remove(lyric_player_module_default.tmpDisableTransition);
			});
		} else {
			this.blur = Math.min(5, blur);
			this.lineTransforms.posX.setTargetPosition(left, delay);
			this.lineTransforms.posY.setTargetPosition(top, delay);
		}
	}
	update(delta = 0) {
		if (!this.lyricPlayer.getEnableSpring()) return;
		this.lineTransforms.posX.update(delta);
		this.lineTransforms.posY.update(delta);
		if (this.isInSight) this.show();
		else this.hide();
	}
	get isInSight() {
		const l = this.lineTransforms.posX.getCurrentPosition();
		const t = this.lineTransforms.posY.getCurrentPosition();
		const r = l + this.lineSize[0];
		const b = t + this.lineSize[1];
		const pr = this.lyricPlayer.size[0];
		const pb = this.lyricPlayer.size[1];
		return !(l > pr || t > pb || r < 0 || b < 0);
	}
	dispose() {
		this.element.remove();
	}
};
//#endregion
//#region src/lyric-player/base/consts.ts
/** 歌词中不雅用语的掩码模式 */
const MaskObsceneWordsMode = {
	/** 禁用任何不雅用语掩码 */
	Disabled: "",
	/** 完全掩码所有不雅用语 */
	FullMask: "full-mask",
	/** 保留首尾字符，屏蔽中间字符 */
	PartialMask: "partial-mask"
};
/**
* 歌词行的渲染模式
* @internal
*/
const LyricLineRenderMode = {
	SOLID: 0,
	GRADIENT: 1
};
/** 布局对齐锚点 */
const LayoutAlignAnchor = {
	Top: "top",
	Center: "center",
	Bottom: "bottom"
};
//#endregion
//#region src/lyric-player/base/layout.ts
/**
* 根据当前时间与当前目标行，计算当前是否处于某个可展示的间奏区间。
*
* 仅识别时间轴上的间奏空档，不涉及具体 DOM 元素的创建与摆放。
* 若当前不应展示间奏动画，则返回 `undefined`。
*/
function computeCurrentInterlude(input) {
	const currentTime = input.currentTime + 20;
	const currentIndex = input.scrollToIndex;
	const lines = input.processedLines;
	const checkGap = (k) => {
		if (k < -1 || k >= lines.length - 1) return void 0;
		const prevLine = k === -1 ? null : lines[k];
		const nextLine = lines[k + 1];
		const gapStart = prevLine ? prevLine.endTime : 0;
		const gapEnd = Math.max(gapStart, nextLine.startTime - 250);
		if (gapEnd - gapStart < 4e3) return;
		if (gapEnd > currentTime && gapStart < currentTime) return {
			startTime: Math.max(gapStart, currentTime),
			endTime: gapEnd,
			anchorLineIndex: k,
			isNextDuet: nextLine.isDuet
		};
	};
	return checkGap(currentIndex - 1) || checkGap(currentIndex) || checkGap(currentIndex + 1);
}
/**
* 根据当前播放上下文计算歌词纵向滚动动画的弹簧参数。
*
* 其策略为：
* - seeking 或间奏时使用更稳定的固定参数
* - 普通播放时根据相邻歌词的时间间隔动态调整 stiffness / damping
*/
function computeLinePosYSpringParams(input) {
	const { enabled, processedLines, scrollToIndex, isSeeking, isInterludeActive } = input;
	if (!enabled || processedLines.length === 0) return { shouldUpdate: false };
	if (isSeeking || isInterludeActive) return {
		shouldUpdate: true,
		params: {
			stiffness: 90,
			damping: 15
		}
	};
	const currentLine = processedLines[scrollToIndex];
	const prevLine = processedLines[scrollToIndex - 1];
	if (!currentLine || !prevLine) return { shouldUpdate: false };
	const interval = currentLine.startTime - (prevLine.words[0]?.startTime ?? prevLine.startTime);
	const MIN_INTERVAL = 100;
	const MAX_INTERVAL = 800;
	const clampedInterval = clamp(interval, MIN_INTERVAL, MAX_INTERVAL);
	const MAX_STIFFNESS = 220;
	const MIN_STIFFNESS = 170;
	let ratio = 1 - (clampedInterval - MIN_INTERVAL) / (MAX_INTERVAL - MIN_INTERVAL);
	ratio = ratio ** .2;
	const targetStiffness = MIN_STIFFNESS + ratio * (MAX_STIFFNESS - MIN_STIFFNESS);
	return {
		shouldUpdate: true,
		params: {
			stiffness: targetStiffness,
			damping: Math.sqrt(targetStiffness) * 2.2
		}
	};
}
/**
* 计算单行歌词在当前布局中的视觉呈现参数。
*
* 根据播放状态、缓冲状态、布局模式与间奏信息，
* 生成一行歌词最终应使用的 opacity、scale、blur 和 render mode。
*/
function computeLinePresentation(input) {
	const { line, lineIndex, scrollToIndex, latestIndex, hasBuffered, hidePassedLines, isPlaying, isNonDynamic, enableScale, enableBlur, isUserScrolling, isCompact, interlude } = input;
	const isActive = hasBuffered || lineIndex >= scrollToIndex && lineIndex < latestIndex;
	const blurLevel = computeLineBlur({
		enableBlur,
		isUserScrolling,
		isActive,
		itemIndex: lineIndex,
		scrollToIndex,
		latestIndex,
		isCompact
	});
	let targetOpacity;
	if (hidePassedLines) if (lineIndex < (interlude ? interlude.anchorLineIndex + 1 : scrollToIndex) && isPlaying) targetOpacity = 1e-4;
	else if (hasBuffered) targetOpacity = .85;
	else targetOpacity = isNonDynamic ? .2 : 1;
	else if (hasBuffered) targetOpacity = .85;
	else targetOpacity = isNonDynamic ? .2 : 1;
	const SCALE_ASPECT = enableScale ? 97 : 100;
	let targetScale = 100;
	if (!isActive && isPlaying) targetScale = line.isBG ? 75 : SCALE_ASPECT;
	return {
		isActive,
		targetOpacity,
		targetScale,
		blurLevel,
		renderMode: isActive ? LyricLineRenderMode.GRADIENT : LyricLineRenderMode.SOLID
	};
}
/**
* 计算一行歌词在当前布局中的模糊等级。
*
* 越远离当前对齐区域的歌词会得到更高的模糊值；
* 活跃行、滚动交互中或关闭模糊效果时返回 `0`。
*/
function computeLineBlur(input) {
	const { enableBlur, isUserScrolling, isActive, itemIndex, scrollToIndex, latestIndex, isCompact } = input;
	if (!enableBlur || isUserScrolling || isActive) return 0;
	let blurLevel = 1;
	if (itemIndex < scrollToIndex) blurLevel += Math.abs(scrollToIndex - itemIndex) + 1;
	else blurLevel += Math.abs(itemIndex - Math.max(scrollToIndex, latestIndex));
	return isCompact ? blurLevel * .8 : blurLevel;
}
//#endregion
//#region src/lyric-player/base/scroll.ts
/**
* 将滚动偏移量限制在当前允许的滚动边界内。
*
* 当手势滚动、滚轮滚动或惯性滚动更新了 {@link PlayerScrollState.scrollOffset}
* 后，应调用本函数以避免视图越界。
*/
function clampPlayerScrollOffset(scrollState) {
	scrollState.scrollOffset = clamp(scrollState.scrollOffset, scrollState.scrollBoundary.minOffset, scrollState.scrollBoundary.maxOffset);
}
/**
* 重置滚动状态到未发生用户滚动时的初始状态。
*
* 本函数会清除当前偏移，并结束“已滚动”与“正在滚动”的标记；
* **不会清理**外部持有的计时器或事件监听器。
*/
function resetPlayerScrollState(scrollState) {
	scrollState.isScrolled = false;
	scrollState.scrollOffset = 0;
	scrollState.isUserScrolling = false;
}
/**
* 向指定元素挂载歌词滚动相关的交互处理器。
*
* 该函数会处理：
* - 触摸拖拽滚动
* - 触摸结束后的惯性滚动
* - 滚轮滚动
* - 轻触时的点击透传
*
* 只更新 {@link PlayerScrollState} 并通过回调通知宿主执行布局或其它副作用，
* 不直接依赖具体的播放器类实现。
*/
function attachPlayerScrollHandlers(element, scrollState, callbacks) {
	let startScrollY = 0;
	let startTouchPosY = 0;
	let startTouchStartX = 0;
	let startTouchStartY = 0;
	let lastMoveY = 0;
	let startScrollTime = 0;
	let scrollSpeed = 0;
	let curScrollId = 0;
	element.addEventListener("touchstart", (evt) => {
		if (callbacks.onBeginScroll()) {
			scrollState.isUserScrolling = true;
			evt.preventDefault();
			startScrollY = scrollState.scrollOffset;
			startTouchPosY = evt.touches[0].screenY;
			lastMoveY = startTouchPosY;
			startTouchStartX = evt.touches[0].screenX;
			startTouchStartY = evt.touches[0].screenY;
			startScrollTime = Date.now();
			scrollSpeed = 0;
			callbacks.onLayout(true, true);
		}
	});
	element.addEventListener("touchmove", (evt) => {
		if (callbacks.onBeginScroll()) {
			evt.preventDefault();
			const currentY = evt.touches[0].screenY;
			const deltaY = currentY - startTouchPosY;
			scrollState.scrollOffset = startScrollY - deltaY;
			clampPlayerScrollOffset(scrollState);
			const now = Date.now();
			const dt = now - startScrollTime;
			if (dt > 0) scrollSpeed = (currentY - lastMoveY) / dt;
			lastMoveY = currentY;
			startScrollTime = now;
			callbacks.onLayout(true, true);
		}
	});
	element.addEventListener("touchend", (evt) => {
		if (callbacks.onBeginScroll()) {
			evt.preventDefault();
			const touch = evt.changedTouches[0];
			const moveX = Math.abs(touch.screenX - startTouchStartX);
			const moveY = Math.abs(touch.screenY - startTouchStartY);
			if (moveX < 10 && moveY < 10) {
				const target = document.elementFromPoint(touch.clientX, touch.clientY);
				if (target instanceof HTMLElement && callbacks.containsTarget(target)) callbacks.clickTarget(target);
				scrollState.isUserScrolling = false;
				callbacks.onEndScroll();
				return;
			}
			startTouchPosY = 0;
			const scrollId = ++curScrollId;
			if (Math.abs(scrollSpeed) < .1) scrollSpeed = 0;
			let lastFrameTime = performance.now();
			const onScrollFrame = (time) => {
				if (scrollId !== curScrollId) return;
				const dt = time - lastFrameTime;
				lastFrameTime = time;
				if (dt <= 0 || dt > 100) {
					requestAnimationFrame(onScrollFrame);
					return;
				}
				if (Math.abs(scrollSpeed) > .05) {
					scrollState.scrollOffset -= scrollSpeed * dt;
					clampPlayerScrollOffset(scrollState);
					const frictionFactor = .95 ** (dt / 16);
					scrollSpeed *= frictionFactor;
					callbacks.onLayout(true, true);
					requestAnimationFrame(onScrollFrame);
				} else {
					scrollState.isUserScrolling = false;
					callbacks.onEndScroll();
				}
			};
			requestAnimationFrame(onScrollFrame);
		} else scrollState.isUserScrolling = false;
	});
	element.addEventListener("wheel", (evt) => {
		if (callbacks.onBeginScroll()) {
			evt.preventDefault();
			if (evt.deltaMode === evt.DOM_DELTA_PIXEL) {
				scrollState.scrollOffset += evt.deltaY;
				clampPlayerScrollOffset(scrollState);
				callbacks.onLayout(true, false);
			} else {
				scrollState.scrollOffset += evt.deltaY * 50;
				clampPlayerScrollOffset(scrollState);
				callbacks.onLayout(false, false);
			}
		}
	}, { passive: false });
}
//#endregion
//#region src/utils/eq-set.ts
const eqSet = (xs, ys) => xs.size === ys.size && [...xs].every((x) => ys.has(x));
//#endregion
//#region src/lyric-player/base/timeline.ts
/**
* 计算指定时间点的热行/缓冲行状态转移的纯函数。其行为包括：
*
* - 根据当前时间和已有的热行状态，计算出新的热行状态，并返回应新增的热行 ID 和应移除的热行 ID
* - 根据新的热行状态和已有的缓冲行状态，计算出应移除的缓冲行 ID
*/
function computePlayerTimeState(input) {
	const { time, processedLines, timelineState: { hotLines, bufferedLines } } = input;
	const nextHotLines = new Set(hotLines);
	const addedIds = /* @__PURE__ */ new Set();
	const removedHotIds = /* @__PURE__ */ new Set();
	const removedBufferedIds = /* @__PURE__ */ new Set();
	for (const lastHotId of hotLines) {
		const line = processedLines[lastHotId];
		if (!line) {
			nextHotLines.delete(lastHotId);
			removedHotIds.add(lastHotId);
			continue;
		}
		if (line.isBG) continue;
		const nextLine = processedLines[lastHotId + 1];
		if (nextLine?.isBG) {
			const nextMainLine = processedLines[lastHotId + 2];
			const startTime = Math.min(line.startTime, nextLine.startTime);
			const endTime = Math.min(Math.max(line.endTime, nextMainLine?.startTime ?? Number.MAX_VALUE), Math.max(line.endTime, nextLine.endTime));
			if (time < startTime || endTime <= time) {
				nextHotLines.delete(lastHotId);
				removedHotIds.add(lastHotId);
				nextHotLines.delete(lastHotId + 1);
				removedHotIds.add(lastHotId + 1);
			}
		} else if (time < line.startTime || line.endTime <= time) {
			nextHotLines.delete(lastHotId);
			removedHotIds.add(lastHotId);
		}
	}
	for (let id = 0; id < processedLines.length; id++) {
		const line = processedLines[id];
		if (!line || line.isBG) continue;
		if (line.startTime <= time && line.endTime > time && !nextHotLines.has(id)) {
			nextHotLines.add(id);
			addedIds.add(id);
			if (processedLines[id + 1]?.isBG) {
				nextHotLines.add(id + 1);
				addedIds.add(id + 1);
			}
		}
	}
	for (const id of bufferedLines) if (!nextHotLines.has(id)) removedBufferedIds.add(id);
	return {
		nextHotLines,
		addedIds,
		removedHotIds,
		removedBufferedIds
	};
}
/**
* 在 seeking 场景下，根据当前时间选出应对齐滚动到的目标行索引。
*
* 若当前仍存在缓冲行，则优先对齐到最靠前的缓冲行；
* 否则对齐到第一条开始时间不小于当前时间的歌词行。
*/
function pickScrollToIndexForSeek(time, processedLines, bufferedLines) {
	if (bufferedLines.size > 0) return Math.min(...bufferedLines);
	const foundIndex = processedLines.findIndex((line) => line.startTime >= time);
	return foundIndex === -1 ? processedLines.length : foundIndex;
}
/**
* 提交时间线状态转移的纯函数。
*
* 把一次时间线状态转移写回 {@link PlayerTimelineState}，
* 并返回一份供宿主执行的副作用应用计划，例如启用/禁用哪些歌词行、
* 是否需要重置用户滚动状态、是否需要触发布局。
*/
function commitPlayerTimeState(input) {
	const { timelineState, time, processedLines, hasBottomContent, stateResult } = input;
	const { addedIds, removedHotIds, removedBufferedIds } = stateResult;
	const { isSeeking } = timelineState;
	timelineState.currentTime = time;
	timelineState.hotLines = stateResult.nextHotLines;
	let shouldLayout = false;
	let shouldResetScroll = false;
	const linesToEnable = [];
	const linesToDisable = /* @__PURE__ */ new Set();
	if (isSeeking) {
		timelineState.bufferedLines = new Set([...timelineState.hotLines]);
		timelineState.scrollToIndex = pickScrollToIndexForSeek(time, processedLines, timelineState.bufferedLines);
		for (const id of removedHotIds) linesToDisable.add(id);
		for (const id of timelineState.hotLines) linesToEnable.push(id);
		for (const id of removedBufferedIds) linesToDisable.add(id);
		shouldResetScroll = true;
		shouldLayout = true;
	} else if (addedIds.size > 0) {
		for (const id of addedIds) {
			timelineState.bufferedLines.add(id);
			linesToEnable.push(id);
		}
		for (const id of removedBufferedIds) {
			timelineState.bufferedLines.delete(id);
			linesToDisable.add(id);
		}
		if (timelineState.bufferedLines.size > 0) timelineState.scrollToIndex = Math.min(...timelineState.bufferedLines);
		shouldLayout = true;
	} else if (removedBufferedIds.size > 0 && eqSet(removedBufferedIds, timelineState.bufferedLines)) {
		for (const id of timelineState.bufferedLines) {
			if (timelineState.hotLines.has(id)) continue;
			timelineState.bufferedLines.delete(id);
			linesToDisable.add(id);
		}
		shouldLayout = true;
	}
	if (timelineState.bufferedLines.size === 0 && processedLines.length > 0) {
		if (time >= processedLines[processedLines.length - 1].endTime) {
			const targetIndex = hasBottomContent ? processedLines.length : processedLines.length - 1;
			if (timelineState.scrollToIndex !== targetIndex) {
				timelineState.scrollToIndex = targetIndex;
				shouldLayout = true;
			}
		}
	}
	timelineState.lastCurrentTime = time;
	return {
		shouldLayout,
		shouldResetScroll,
		linesToEnable,
		linesToDisable: [...linesToDisable]
	};
}
//#endregion
//#region src/lyric-player/base/index.ts
/**
* 歌词播放器的基类，已经包含了有关歌词操作和排版的功能，
* 子类需要为其实现对应的显示展示操作
*/
var LyricPlayerBase = class extends EventTarget {
	element = document.createElement("div");
	/** 播放时间线状态 */
	timelineState = {
		currentTime: 0,
		lastCurrentTime: 0,
		hotLines: /* @__PURE__ */ new Set(),
		bufferedLines: /* @__PURE__ */ new Set(),
		scrollToIndex: 0,
		isSeeking: false,
		isPlaying: true,
		initialLayoutFinished: false
	};
	/** @internal */
	lyricLinesSize = /* @__PURE__ */ new WeakMap();
	/** @internal */
	lyricLineElementMap = /* @__PURE__ */ new WeakMap();
	currentLyricLines = [];
	processedLines = [];
	lyricLinesIndexes = /* @__PURE__ */ new WeakMap();
	isNonDynamic = false;
	hasDuetLine = false;
	disableSpring = false;
	layoutState = {
		interludeDotsSize: [0, 0],
		targetAlignIndex: 0,
		lastInterludeState: false,
		alignAnchor: LayoutAlignAnchor.Center,
		alignPosition: .35,
		overscanPx: 300
	};
	interludeDots = new InterludeDots();
	bottomLine = new BottomLineEl(this);
	enableBlur = true;
	enableScale = true;
	maskObsceneWords = MaskObsceneWordsMode.Disabled;
	maskObsceneWordChar = "*";
	hidePassedLines = false;
	scrollState = {
		scrollBoundary: {
			minOffset: 0,
			maxOffset: 0
		},
		scrollOffset: 0,
		allowScroll: true,
		isScrolled: false,
		isUserScrolling: false
	};
	currentLyricLineObjects = [];
	size = [0, 0];
	isPageVisible = true;
	optimizeOptions = {};
	posXSpringParams = {
		mass: 1,
		damping: 10,
		stiffness: 100
	};
	posYSpringParams = {
		mass: .9,
		damping: 15,
		stiffness: 90
	};
	scaleSpringParams = {
		mass: 2,
		damping: 25,
		stiffness: 100
	};
	scaleForBGSpringParams = {
		mass: 1,
		damping: 20,
		stiffness: 50
	};
	onPageShow = () => {
		this.isPageVisible = true;
		this.setCurrentTime(this.timelineState.currentTime, true);
	};
	onPageHide = () => {
		this.isPageVisible = false;
	};
	scrolledHandler;
	/** @internal */
	resizeObserver = new ResizeObserver(((entries) => {
		let shouldRelayout = false;
		let shouldRebuildPlayerStyle = false;
		for (const entry of entries) if (entry.target === this.element) {
			const rect = entry.contentRect;
			this.size[0] = rect.width;
			this.size[1] = rect.height;
			shouldRebuildPlayerStyle = true;
		} else if (entry.target === this.interludeDots.getElement()) {
			this.layoutState.interludeDotsSize[0] = entry.target.clientWidth;
			this.layoutState.interludeDotsSize[1] = entry.target.clientHeight;
			shouldRelayout = true;
		} else if (entry.target === this.bottomLine.getElement()) {
			const newSize = [entry.target.clientWidth, entry.target.clientHeight];
			const oldSize = this.bottomLine.lineSize;
			if (newSize[0] !== oldSize[0] || newSize[1] !== oldSize[1]) {
				this.bottomLine.lineSize = newSize;
				shouldRelayout = true;
			}
		} else {
			const lineObj = this.lyricLineElementMap.get(entry.target);
			if (lineObj) {
				const newSize = [entry.target.clientWidth, entry.target.clientHeight];
				const oldSize = this.lyricLinesSize.get(lineObj) ?? [0, 0];
				if (newSize[0] !== oldSize[0] || newSize[1] !== oldSize[1]) {
					this.lyricLinesSize.set(lineObj, newSize);
					lineObj.onLineSizeChange(newSize);
					shouldRelayout = true;
				}
			}
		}
		if (shouldRelayout) this.calcLayout(true);
		if (shouldRebuildPlayerStyle) this.onResize();
	}));
	wordFadeWidth = .5;
	constructor(element) {
		super();
		if (element) this.element = element;
		this.element.classList.add("amll-lyric-player");
		this.resizeObserver.observe(this.element);
		this.resizeObserver.observe(this.interludeDots.getElement());
		this.element.appendChild(this.interludeDots.getElement());
		this.element.appendChild(this.bottomLine.getElement());
		this.interludeDots.setTransform(0, 200);
		window.addEventListener("pageshow", this.onPageShow);
		window.addEventListener("pagehide", this.onPageHide);
		attachPlayerScrollHandlers(this.element, this.scrollState, {
			onBeginScroll: () => this.beginScrollHandler(),
			onEndScroll: () => this.endScrollHandler(),
			onLayout: (sync, force) => this.calcLayout(sync, force),
			containsTarget: (target) => this.element.contains(target),
			clickTarget: (target) => target.click()
		});
	}
	beginScrollHandler() {
		const allowed = this.scrollState.allowScroll;
		if (allowed) {
			this.scrollState.isScrolled = true;
			clearTimeout(this.scrolledHandler);
			this.scrolledHandler = setTimeout(() => {
				this.scrollState.isScrolled = false;
				this.scrollState.scrollOffset = 0;
			}, 5e3);
		}
		return allowed;
	}
	endScrollHandler() {}
	/**
	* 设置文字动画的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位，默认为 0.5，即一个全角字符的一半宽度
	*
	* 如果要模拟 Apple Music for Android 的效果，可以设置为 1
	*
	* 如果要模拟 Apple Music for iPad 的效果，可以设置为 0.5
	*
	* 如果想要近乎禁用渐变效果，可以设置成非常接近 0 的小数（例如 `0.0001` ），但是**不可以为 0**
	*
	* @param value 需要设置的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位，默认为 0.5
	*/
	setWordFadeWidth(value = .5) {
		this.wordFadeWidth = Math.max(1e-4, value);
	}
	/**
	* 是否启用歌词行缩放效果，默认启用
	*
	* 如果启用，非选中的歌词行会轻微缩小以凸显当前播放歌词行效果
	*
	* 此效果对性能影响微乎其微，推荐启用
	* @param enable 是否启用歌词行缩放效果
	*/
	setEnableScale(enable = true) {
		this.enableScale = enable;
		this.calcLayout();
	}
	/**
	* 获取当前是否启用了歌词行缩放效果
	* @returns 是否启用歌词行缩放效果
	*/
	getEnableScale() {
		return this.enableScale;
	}
	/**
	* 获取当前文字动画的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位
	* @returns 当前文字动画的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位
	*/
	getWordFadeWidth() {
		return this.wordFadeWidth;
	}
	setIsSeeking(isSeeking) {
		this.timelineState.isSeeking = isSeeking;
	}
	/**
	* 设置是否隐藏已经播放过的歌词行，默认不隐藏
	* @param hide 是否隐藏已经播放过的歌词行，默认不隐藏
	*/
	setHidePassedLines(hide) {
		this.hidePassedLines = hide;
		this.calcLayout();
	}
	/**
	* 设置是否启用歌词行的模糊效果
	* @param enable 是否启用
	*/
	setEnableBlur(enable) {
		if (this.enableBlur === enable) return;
		this.enableBlur = enable;
		this.calcLayout();
	}
	/**
	* 设置歌词中不雅用语的掩码模式
	* @param mode 掩码模式
	* @see {@link MaskObsceneWordsMode}
	*/
	setMaskObsceneWords(mode) {
		if (this.maskObsceneWords === mode) return;
		this.maskObsceneWords = mode;
		this.rebuildLyricLines();
		this.calcLayout();
	}
	/**
	* 设置不雅用语掩码使用的字符，默认为 `*`
	* @param char 单个字符，用于替换不雅用语中的字符
	*/
	setMaskObsceneWordChar(char) {
		const c = char.charAt(0) || "*";
		if (this.maskObsceneWordChar === c) return;
		this.maskObsceneWordChar = c;
		if (this.maskObsceneWords !== MaskObsceneWordsMode.Disabled) {
			this.rebuildLyricLines();
			this.calcLayout();
		}
	}
	rebuildLyricLines() {
		for (const lineObj of this.currentLyricLineObjects) lineObj.rebuildElement();
	}
	/**
	* 根据当前配置处理不雅用语单词
	* @param word 单词对象
	* @internal
	*/
	processObsceneWord(word) {
		const text = word.word;
		if (!word.obscene || this.maskObsceneWords === MaskObsceneWordsMode.Disabled) return text;
		const maskChar = this.maskObsceneWordChar;
		if (this.maskObsceneWords === MaskObsceneWordsMode.FullMask) return text.replace(/\S/g, maskChar);
		if (this.maskObsceneWords === MaskObsceneWordsMode.PartialMask) {
			const trimmed = text.trim();
			if (trimmed.length <= 2) return text.replace(/\S/g, maskChar);
			const startPos = text.indexOf(trimmed);
			const endPos = startPos + trimmed.length - 1;
			return text.slice(0, startPos + 1) + text.slice(startPos + 1, endPos).replace(/\S/g, maskChar) + text.slice(endPos);
		}
		return text;
	}
	/**
	* 设置目标歌词行的对齐方式，默认为 `center`
	*
	* - 设置成 `top` 的话将会向目标歌词行的顶部对齐
	* - 设置成 `bottom` 的话将会向目标歌词行的底部对齐
	* - 设置成 `center` 的话将会向目标歌词行的垂直中心对齐
	* @param alignAnchor 歌词行对齐方式，详情见函数说明
	*/
	setAlignAnchor(alignAnchor) {
		this.layoutState.alignAnchor = alignAnchor;
	}
	/**
	* 设置默认的歌词行对齐位置，相对于整个歌词播放组件的大小位置，默认为 `0.5`
	* @param alignPosition 一个 `[0.0-1.0]` 之间的任意数字，代表组件高度由上到下的比例位置
	*/
	setAlignPosition(alignPosition) {
		this.layoutState.alignPosition = alignPosition;
	}
	/**
	* 设置 overscan（视图上下额外缓冲渲染区）距离，单位：像素。
	* @param px 像素值，默认 300
	*/
	setOverscanPx(px) {
		this.layoutState.overscanPx = clampPositive(px | 0);
	}
	/** 获取当前 overscan 像素距离 */
	getOverscanPx() {
		return this.layoutState.overscanPx;
	}
	/**
	* 设置是否使用物理弹簧算法实现歌词动画效果，默认启用
	*
	* 如果启用，则会通过弹簧算法实时处理歌词位置，但是需要性能足够强劲的电脑方可流畅运行
	*
	* 如果不启用，则会回退到基于 `transition` 的过渡效果，对低性能的机器比较友好，但是效果会比较单一
	*/
	setEnableSpring(enable = true) {
		this.disableSpring = !enable;
		if (enable) this.element.classList.remove(lyric_player_module_default.disableSpring);
		else this.element.classList.add(lyric_player_module_default.disableSpring);
		this.calcLayout(true);
	}
	/**
	* 获取当前是否启用了物理弹簧
	* @returns 是否启用物理弹簧
	*/
	getEnableSpring() {
		return !this.disableSpring;
	}
	/**
	* 设置歌词的优化配置项，这些配置项默认全部开启
	*
	* 注意，如果在 `setLyricLines` 之后修改此配置，需要重新调用 `setLyricLines()` 才能对当前歌词生效
	* @param options 优化配置选项
	* @see {@link OptimizeLyricOptions}
	*/
	setOptimizeOptions(options) {
		this.optimizeOptions = {
			...this.optimizeOptions,
			...options
		};
	}
	/**
	* 设置当前播放歌词，要注意传入后这个数组内的信息不得修改，否则会发生错误
	* @param lines 歌词数组
	* @param initialTime 初始时间，默认为 0
	*/
	setLyricLines(lines, initialTime = 0) {
		this.timelineState.initialLayoutFinished = true;
		this.timelineState.lastCurrentTime = initialTime;
		this.timelineState.currentTime = initialTime;
		this.currentLyricLines = esm_default(lines);
		this.processedLines = esm_default(this.currentLyricLines);
		optimizeLyricLines(this.processedLines, this.optimizeOptions);
		this.isNonDynamic = true;
		for (const line of this.processedLines) if (line.words.length > 1) {
			this.isNonDynamic = false;
			break;
		}
		this.hasDuetLine = this.processedLines.some((line) => line.isDuet);
		for (const line of this.currentLyricLineObjects) line.dispose();
		this.interludeDots.setInterlude(void 0);
		this.timelineState.hotLines.clear();
		this.timelineState.bufferedLines.clear();
		this.setCurrentTime(0, true);
	}
	/**
	* 获取当前是否在播放
	* @returns 当前是否在播放
	*/
	getIsPlaying() {
		return this.timelineState.isPlaying;
	}
	/**
	* 设置当前播放进度，此时将会更新内部的歌词进度信息。
	*
	* 内部会根据调用间隔和播放进度自动决定如何滚动和显示歌词，所以这个的调用频率越快越准确越好。
	* 调用完成后，应每帧调用 {@link update} 方法来执行歌词动画效果。**此函数本身不会触发动画效果**。
	*
	* @param time 当前播放进度，单位为毫秒
	*/
	setCurrentTime(time, isSeek = false) {
		time = Math.round(time);
		const { timelineState } = this;
		timelineState.isSeeking = Boolean(isSeek);
		timelineState.currentTime = time;
		if (!timelineState.initialLayoutFinished && !timelineState.isSeeking) return;
		const stateResult = computePlayerTimeState({
			time,
			processedLines: this.processedLines,
			timelineState
		});
		const hasBottomContent = this.bottomLine.getElement().innerHTML.trim().length > 0;
		const commitResult = commitPlayerTimeState({
			timelineState,
			time,
			processedLines: this.processedLines,
			hasBottomContent,
			stateResult
		});
		for (const id of commitResult.linesToDisable) this.currentLyricLineObjects[id]?.disable();
		for (const id of commitResult.linesToEnable) this.currentLyricLineObjects[id]?.enable();
		if (commitResult.shouldResetScroll) this.resetScroll();
		if (commitResult.shouldLayout) this.calcLayout();
	}
	/**
	* 重新布局定位歌词行的位置，调用完成后再逐帧调用 `update`
	* 函数即可让歌词通过动画移动到目标位置。
	*
	* 函数有一个 `force` 参数，用于指定是否强制修改布局，也就是不经过动画直接调整元素位置和大小。
	*
	* 此函数还有一个 `reflow` 参数，用于指定是否需要重新计算布局
	*
	* 因为计算布局必定会导致浏览器重排布局，所以会大幅度影响流畅度和性能，故请只在以下情况下将其​设置为 true：
	*
	* 1. 歌词页面大小发生改变时（这个组件会自行处理）
	* 2. 加载了新的歌词时（不论前后歌词是否完全一样）
	* 3. 用户自行跳转了歌曲播放位置（不论距离远近）
	*
	* @param sync 是否同步执行，通常用于初始化或 Resize 时立即布局
	* @param force 是否绕过弹簧效果强制更新位置
	*/
	async calcLayout(sync = false, force = false) {
		const interlude = computeCurrentInterlude({
			currentTime: this.timelineState.currentTime,
			scrollToIndex: this.timelineState.scrollToIndex,
			processedLines: this.processedLines
		});
		const isInterludeActive = !!interlude;
		if (this.layoutState.targetAlignIndex !== this.timelineState.scrollToIndex || this.layoutState.lastInterludeState !== isInterludeActive) {
			this.layoutState.lastInterludeState = isInterludeActive;
			const springParams = computeLinePosYSpringParams({
				enabled: this.getEnableSpring(),
				processedLines: this.processedLines,
				scrollToIndex: this.timelineState.scrollToIndex,
				isSeeking: this.timelineState.isSeeking,
				isInterludeActive
			});
			if (springParams.shouldUpdate && springParams.params) this.setLinePosYSpringParams(springParams.params);
		}
		let curPos = -this.scrollState.scrollOffset;
		const targetAlignIndex = this.timelineState.scrollToIndex;
		let isNextDuet = false;
		if (interlude) isNextDuet = interlude.isNextDuet;
		else this.interludeDots.setInterlude(void 0);
		const dotMargin = (this.baseFontSize || 24) * .4;
		const totalInterludeHeight = this.layoutState.interludeDotsSize[1] + dotMargin * 2;
		if (interlude) {
			if (interlude.anchorLineIndex !== -1) curPos -= totalInterludeHeight;
		}
		const LINE_HEIGHT_FALLBACK = this.size[1] / 5;
		const scrollOffset = this.currentLyricLineObjects.slice(0, targetAlignIndex).reduce((acc, el) => acc + (el.getLine().isBG && this.timelineState.isPlaying ? 0 : this.lyricLinesSize.get(el)?.[1] ?? LINE_HEIGHT_FALLBACK), 0);
		this.scrollState.scrollBoundary.minOffset = -scrollOffset;
		curPos -= scrollOffset;
		curPos += this.size[1] * this.layoutState.alignPosition;
		const curLine = this.currentLyricLineObjects[targetAlignIndex];
		this.layoutState.targetAlignIndex = targetAlignIndex;
		const isBottomFocused = targetAlignIndex === this.currentLyricLineObjects.length;
		this.bottomLine.setFocused(isBottomFocused);
		let targetLineHeight = 0;
		if (curLine) targetLineHeight = this.lyricLinesSize.get(curLine)?.[1] ?? LINE_HEIGHT_FALLBACK;
		else if (isBottomFocused) targetLineHeight = this.bottomLine.lineSize[1];
		if (targetLineHeight > 0) switch (this.layoutState.alignAnchor) {
			case LayoutAlignAnchor.Bottom:
				curPos -= targetLineHeight;
				break;
			case LayoutAlignAnchor.Center:
				curPos -= targetLineHeight / 2;
				break;
			case LayoutAlignAnchor.Top: break;
		}
		const latestIndex = Math.max(...this.timelineState.bufferedLines);
		let delay = 0;
		let baseDelay = sync ? 0 : .05;
		let setDots = false;
		this.currentLyricLineObjects.forEach((lineObj, i) => {
			const hasBuffered = this.timelineState.bufferedLines.has(i);
			const line = lineObj.getLine();
			const shouldShowDots = interlude && i === interlude.anchorLineIndex + 1;
			if (!setDots && shouldShowDots) {
				setDots = true;
				curPos += dotMargin;
				let targetX = 0;
				if (interlude && isNextDuet) targetX = this.size[0] - this.layoutState.interludeDotsSize[0];
				this.interludeDots.setTransform(targetX, curPos);
				if (interlude) this.interludeDots.setInterlude([interlude.startTime, interlude.endTime]);
				curPos += this.layoutState.interludeDotsSize[1];
				curPos += dotMargin;
			}
			const presentation = computeLinePresentation({
				line,
				lineIndex: i,
				scrollToIndex: this.timelineState.scrollToIndex,
				latestIndex,
				hasBuffered,
				hidePassedLines: this.hidePassedLines,
				isPlaying: this.timelineState.isPlaying,
				isNonDynamic: this.isNonDynamic,
				enableScale: this.enableScale,
				enableBlur: this.enableBlur,
				isUserScrolling: this.scrollState.isUserScrolling,
				isCompact: window.innerWidth <= 1024,
				interlude
			});
			lineObj.setTransform(curPos, presentation.targetScale, presentation.targetOpacity, presentation.blurLevel, force, delay, presentation.renderMode);
			if (line.isBG && (presentation.isActive || !this.timelineState.isPlaying)) curPos += this.lyricLinesSize.get(lineObj)?.[1] ?? LINE_HEIGHT_FALLBACK;
			else if (!line.isBG) curPos += this.lyricLinesSize.get(lineObj)?.[1] ?? LINE_HEIGHT_FALLBACK;
			if (curPos >= 0 && !this.timelineState.isSeeking) {
				if (!line.isBG) delay += baseDelay;
				if (i >= this.timelineState.scrollToIndex) baseDelay /= 1.05;
			}
		});
		this.scrollState.scrollBoundary.maxOffset = curPos + this.scrollState.scrollOffset - this.size[1] / 2;
		const bottomIndex = this.currentLyricLineObjects.length;
		const finalBottomBlur = computeLineBlur({
			enableBlur: this.enableBlur,
			isUserScrolling: this.scrollState.isUserScrolling,
			isActive: isBottomFocused,
			itemIndex: bottomIndex,
			scrollToIndex: this.timelineState.scrollToIndex,
			latestIndex,
			isCompact: window.innerWidth <= 1024
		});
		this.bottomLine.setTransform(0, curPos, finalBottomBlur, force, delay);
	}
	/**
	* 设置所有歌词行在横坐标上的弹簧属性，包括重量、弹力和阻力。
	*
	* @param params 需要设置的弹簧属性，提供的属性将会覆盖原来的属性，未提供的属性将会保持原样
	* @deprecated 考虑到横向弹簧效果并不常见，所以这个函数将会在未来的版本中移除
	*/
	setLinePosXSpringParams(_params = {}) {}
	/**
	* 设置所有歌词行在​纵坐标上的弹簧属性，包括重量、弹力和阻力。
	*
	* @param params 需要设置的弹簧属性，提供的属性将会覆盖原来的属性，未提供的属性将会保持原样
	*/
	setLinePosYSpringParams(params = {}) {
		this.posYSpringParams = {
			...this.posYSpringParams,
			...params
		};
		this.bottomLine.lineTransforms.posY.updateParams(this.posYSpringParams);
		for (const line of this.currentLyricLineObjects) line.lineTransforms.posY.updateParams(this.posYSpringParams);
	}
	/**
	* 设置所有歌词行在​缩放大小上的弹簧属性，包括重量、弹力和阻力。
	*
	* @param params 需要设置的弹簧属性，提供的属性将会覆盖原来的属性，未提供的属性将会保持原样
	*/
	setLineScaleSpringParams(params = {}) {
		this.scaleSpringParams = {
			...this.scaleSpringParams,
			...params
		};
		this.scaleForBGSpringParams = {
			...this.scaleForBGSpringParams,
			...params
		};
		for (const lineObj of this.currentLyricLineObjects) if (lineObj.getLine().isBG) lineObj.lineTransforms.scale.updateParams(this.scaleForBGSpringParams);
		else lineObj.lineTransforms.scale.updateParams(this.scaleSpringParams);
	}
	/**
	* 暂停部分效果演出，目前会暂停播放间奏点的动画，且将背景歌词显示出来
	*/
	pause() {
		this.interludeDots.pause();
		if (this.timelineState.isPlaying) {
			this.timelineState.isPlaying = false;
			this.calcLayout();
		}
	}
	/**
	* 恢复部分效果演出，目前会恢复播放间奏点的动画
	*/
	resume() {
		this.interludeDots.resume();
		if (!this.timelineState.isPlaying) {
			this.timelineState.isPlaying = true;
			this.calcLayout();
		}
	}
	/**
	* 更新动画，这个函数应该被逐帧调用或者在以下情况下调用一次：
	*
	* 1. 刚刚调用完设置歌词函数的时候
	* @param delta 距离上一次被调用到现在的时长，单位为毫秒（可为浮点数）
	*/
	update(delta = 0) {
		this.bottomLine.update(delta / 1e3);
		this.interludeDots.update(delta);
	}
	onResize() {}
	/**
	* 获取一个特殊的底栏元素，默认是空白的，可以往内部添加任意元素
	*
	* 这个元素始终在歌词的底部，可以用于显示歌曲创作者等信息
	*
	* 但是请勿删除该元素，只能在内部存放元素
	*
	* @returns 一个元素，可以往内部添加任意元素
	*/
	getBottomLineElement() {
		return this.bottomLine.getElement();
	}
	/**
	* 重置用户滚动状态
	*
	* 请在用户完成滚动点击跳转歌词时调用本事件再调用 `calcLayout` 以正确滚动到目标位置
	*/
	resetScroll() {
		resetPlayerScrollState(this.scrollState);
		clearTimeout(this.scrolledHandler);
	}
	/**
	* 获取当前歌词数组
	*
	* 一般和最后调用 `setLyricLines` 给予的参数一样
	* @returns 当前歌词数组
	*/
	getLyricLines() {
		return this.currentLyricLines;
	}
	/**
	* 获取当前歌词的播放位置
	*
	* 一般和最后调用 `setCurrentTime` 给予的参数一样
	* @returns 当前播放位置
	*/
	getCurrentTime() {
		return this.timelineState.currentTime;
	}
	getElement() {
		return this.element;
	}
	dispose() {
		this.element.remove();
		window.removeEventListener("pageshow", this.onPageShow);
		window.removeEventListener("pagehide", this.onPageHide);
	}
};
//#endregion
//#region ../../node_modules/.pnpm/bezier-easing@3.0.0/node_modules/bezier-easing/src/index.js
/**
* https://github.com/gre/bezier-easing
* BezierEasing - use bezier curve for transition easing function
* by Gaëtan Renaudeau 2014 - 2015 – MIT License
*
* Algebraic solver by Dmitry Baranovskiy
* http://dmitry.baranovskiy.com/bezier-easing.html
*/
function LinearEasing(x) {
	return x;
}
const { cbrt, sqrt, PI: π } = Math;
const x2t = (x, a, b, c, d) => {
	const q = a + b * x;
	const s = q ** 2 + c;
	if (s > 0) {
		const root = sqrt(s);
		return cbrt(q + root) + cbrt(q - root) - d;
	}
	const l = cbrt(sqrt(q * q - s));
	const angle = q ? Math.atan(sqrt(-s) / q) : -π / 2;
	let φ;
	if (b < 0) φ = (q > 0 ? 2 * π : π) - angle;
	else if (d < 0) φ = (q > 0 ? 2 * π : -3 * π) + angle;
	else φ = (q > 0 ? 0 : π) + angle;
	return 2 * l * Math.cos(φ / 3) - d;
};
const Y = (t, ay, by, cy) => ((ay * t + 3 * by) * t + cy) * t;
function bezier(mX1, mY1, mX2, mY2) {
	if (!(0 <= mX1 && mX1 <= 1 && 0 <= mX2 && mX2 <= 1)) throw new Error("bezier x values must be in [0, 1] range");
	if (mX1 === mY1 && mX2 === mY2) return LinearEasing;
	const a = 6 * (3 * mX1 - 3 * mX2 + 1);
	const b = 6 * (mX2 - 2 * mX1);
	const c = 3 * mX1;
	const a2 = a * a;
	const b2 = b * b;
	const d = b / a;
	const e = 3 * b * c / a2 - b2 * b / (a2 * a);
	const w1 = 2 * c / a - b2 / a2;
	const w = w1 * w1 * w1;
	const o = 3 / a;
	const ay = 3 * mY1 - 3 * mY2 + 1;
	const by = mY2 - 2 * mY1;
	const cy = 3 * mY1;
	const X2T = a ? x2t : LinearEasing;
	return function BezierEasing(x) {
		if (x === 0 || x === 1) return x;
		return Y(X2T(x, e, o, w, d), ay, by, cy);
	};
}
//#endregion
//#region src/utils/is-cjk.ts
const isCJK = (char) => {
	return /^[\p{Unified_Ideograph}\u0800-\u9FFC]+$/u.test(char);
};
//#endregion
//#region src/lyric-player/base/line.ts
/**
* 所有标准歌词行的基类
* @internal
*/
var LyricLineBase = class extends EventTarget {
	top = 0;
	scale = 1;
	blur = 0;
	opacity = 1;
	delay = 0;
	lineTransforms = {
		posY: new Spring(0),
		scale: new Spring(100)
	};
	/**
	* 用于 CJK 词语边界检测的分词器
	*/
	static wordSegmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(void 0, { granularity: "word" }) : null;
	/**
	* Unicode 标准的全局 Grapheme Cluster 分词器
	* 用于正确处理 emoji、复合字符等
	*/
	static graphemeSegmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(void 0, { granularity: "grapheme" }) : null;
	onLineSizeChange(_size) {}
	setTransform(top = this.top, scale = this.scale, opacity = this.opacity, blur = this.blur, _force = false, delay = 0, _mode = LyricLineRenderMode.SOLID) {
		this.top = top;
		this.scale = scale;
		this.opacity = opacity;
		this.blur = blur;
		this.delay = delay;
	}
	rebuildElement() {}
	/**
	* 判定歌词是否可以应用强调辉光效果
	*
	* 果子在对辉光效果的解释是一种强调（emphasized）效果
	*
	* 条件是一个单词时长大于等于 1s 且长度小于等于 7
	*
	* @param word 单词
	* @returns 是否可以应用强调辉光效果
	*/
	static shouldEmphasize(word) {
		if (isCJK(word.word)) return word.endTime - word.startTime >= 1e3;
		return word.endTime - word.startTime >= 1e3 && word.word.trim().length <= 7 && word.word.trim().length > 1;
	}
	dispose() {}
};
//#endregion
//#region src/utils/lyric-line-break.ts
/**
* 单个词超过容器宽度时的大惩罚倍数
*/
const OVERFLOW_PENALTY_MULTIPLIER = 1e3;
/**
* 截断 CJK 词组边界的惩罚比例
*
* 相对于容器宽度
*/
const CJK_BREAK_PENALTY_RATIO = .15;
/**
* 截断普通文本（非空格、非 CJK 词界）的惩罚比例
*/
const NORMAL_BREAK_PENALTY_RATIO = .5;
/**
* 在空格处断开的奖励比例
*/
const SPACE_BREAK_REWARD_RATIO = .4;
/**
* 在标点符号处断开的奖励比例
*
* 比空格更高以便优先一点在标点处换行
*/
const PUNCTUATION_BREAK_REWARD_RATIO = .6;
const PUNCTUATION_REGEX = /[,.;:!?，。；：！？、）】》」』’”)[\]}>~…]$/;
/**
* 计算平均行长度的断点位置
* @param children 子节点信息
* @param containerWidth 容器可用内容宽度
* @param fullText 完整的行文本
* @param segmenter 预创建的 Intl.Segmenter 分词器
* @returns 需要在其前面插入 `<br>` 的子节点索引数组，升序
*/
function calcBalancedBreaks(children, containerWidth, fullText, segmenter) {
	const n = children.length;
	if (n === 0 || containerWidth <= 0) return [];
	const cjkBoundaries = /* @__PURE__ */ new Set();
	let offset = 0;
	for (const { segment, isWordLike } of segmenter.segment(fullText)) {
		if (offset > 0 && isWordLike) {
			if ([...segment].some((ch) => isCJK(ch))) cjkBoundaries.add(offset);
		}
		offset += segment.length;
	}
	const charOffsets = new Int32Array(n + 1);
	const prefixWidth = new Float64Array(n + 1);
	for (let i = 0; i < n; i++) {
		charOffsets[i + 1] = charOffsets[i] + children[i].text.length;
		prefixWidth[i + 1] = prefixWidth[i] + children[i].width;
	}
	if (prefixWidth[n] <= containerWidth) return [];
	/**
	* dp[i] 表示将 index i 到 n-1 的节点进行排版的最小代价
	*/
	const dp = new Float64Array(n + 1).fill(Number.POSITIVE_INFINITY);
	const nextBreak = new Int32Array(n + 1).fill(-1);
	dp[n] = 0;
	const PENALTY_CJK = (containerWidth * CJK_BREAK_PENALTY_RATIO) ** 2;
	const PENALTY_NORMAL = (containerWidth * NORMAL_BREAK_PENALTY_RATIO) ** 2;
	for (let i = n - 1; i >= 0; i--) for (let j = i + 1; j <= n; j++) {
		const w = prefixWidth[j] - prefixWidth[i];
		let lineCost = 0;
		if (w > containerWidth) if (j === i + 1) lineCost = (w - containerWidth) ** 2 * OVERFLOW_PENALTY_MULTIPLIER;
		else continue;
		else lineCost = (containerWidth - w) ** 2;
		let breakPenalty = 0;
		if (j < n) {
			const prevChild = children[j - 1];
			if (PUNCTUATION_REGEX.test(prevChild.text)) breakPenalty = -((containerWidth * PUNCTUATION_BREAK_REWARD_RATIO) ** 2);
			else if (prevChild.isSpace) breakPenalty = -((containerWidth * SPACE_BREAK_REWARD_RATIO) ** 2);
			else if (cjkBoundaries.has(charOffsets[j])) breakPenalty = PENALTY_CJK;
			else breakPenalty = PENALTY_NORMAL;
		}
		const totalCost = lineCost + breakPenalty + dp[j];
		if (totalCost < dp[i]) {
			dp[i] = totalCost;
			nextBreak[i] = j;
		}
	}
	const breaks = [];
	let curr = 0;
	while (curr < n) {
		curr = nextBreak[curr];
		if (curr > 0 && curr < n) breaks.push(curr);
	}
	return breaks;
}
//#endregion
//#region src/utils/line-balancer.ts
let sharedCanvasCtx = null;
function getMeasurementContext() {
	if (!sharedCanvasCtx) sharedCanvasCtx = document.createElement("canvas").getContext("2d");
	return sharedCanvasCtx;
}
/**
* 用于平衡歌词行在换行后的各行长度
*/
var LineBalancer = class {
	isBalancing = false;
	lastBalancedContainerWidth = -1;
	constructor(mainElement) {
		this.mainElement = mainElement;
	}
	balanceLineBreaks(isNonDynamic, hasSplittedWords, wordSegmenter) {
		if (this.isBalancing || !this.mainElement) return;
		const computedStyle = getComputedStyle(this.mainElement);
		const paddingLeft = Number.parseFloat(computedStyle.paddingLeft) || 0;
		const paddingRight = Number.parseFloat(computedStyle.paddingRight) || 0;
		const containerWidth = this.mainElement.clientWidth - paddingLeft - paddingRight;
		if (containerWidth <= 0) return;
		if (isNonDynamic) {
			this.balanceNonDynamicLineBreaks(containerWidth, computedStyle, wordSegmenter);
			return;
		}
		if (!hasSplittedWords) return;
		this.balanceDynamicLineBreaks(containerWidth, wordSegmenter);
	}
	reset() {
		this.lastBalancedContainerWidth = -1;
	}
	executeLineBalance(containerWidth, adapter, wordSegmenter) {
		const existingBrs = this.mainElement.querySelectorAll("br");
		if (containerWidth === this.lastBalancedContainerWidth && existingBrs.length > 0) return;
		adapter.resetDOM();
		const prevWhiteSpace = this.mainElement.style.whiteSpace;
		this.mainElement.style.whiteSpace = "nowrap";
		const parentElement = this.mainElement.parentElement;
		let prevTransform = "";
		let transformChanged = false;
		if (parentElement) {
			prevTransform = parentElement.style.transform;
			if (prevTransform && prevTransform !== "none") {
				parentElement.style.transform = "none";
				transformChanged = true;
			}
		}
		let lockAcquired = false;
		try {
			const { childInfos, fullText } = adapter.buildChildInfos();
			let layoutWidth = childInfos.reduce((sum, c) => sum + c.width, 0);
			if (adapter.needsCalibration) {
				const range = document.createRange();
				range.selectNodeContents(this.mainElement);
				const visualWidth = range.getBoundingClientRect().width;
				if (layoutWidth > 0 && visualWidth > 0) {
					const scale = visualWidth / layoutWidth;
					for (const info of childInfos) info.width *= scale;
				}
				layoutWidth = visualWidth;
			}
			const safeContainerWidth = Math.max(1, containerWidth);
			if (layoutWidth <= safeContainerWidth) {
				this.lastBalancedContainerWidth = containerWidth;
				return;
			}
			const breaks = calcBalancedBreaks(childInfos, safeContainerWidth, fullText, wordSegmenter);
			if (breaks.length === 0) {
				this.lastBalancedContainerWidth = containerWidth;
				return;
			}
			this.isBalancing = true;
			lockAcquired = true;
			adapter.applyBreaks(breaks, childInfos);
			this.lastBalancedContainerWidth = containerWidth;
			this.isBalancing = false;
		} finally {
			this.mainElement.style.whiteSpace = prevWhiteSpace;
			if (transformChanged && parentElement) parentElement.style.transform = prevTransform;
			if (lockAcquired) this.isBalancing = false;
		}
	}
	balanceDynamicLineBreaks(containerWidth, wordSegmenter) {
		const infoToNode = [];
		this.executeLineBalance(containerWidth, {
			resetDOM: () => {
				this.mainElement.querySelectorAll("br").forEach((br) => {
					br.remove();
				});
			},
			buildChildInfos: () => {
				infoToNode.length = 0;
				const childNodes = Array.from(this.mainElement.childNodes);
				const childInfos = [];
				const range = document.createRange();
				for (const node of childNodes) if (node.nodeType === Node.TEXT_NODE) {
					const text = node.textContent ?? "";
					if (text.length === 0) continue;
					range.selectNodeContents(node);
					childInfos.push({
						width: range.getBoundingClientRect().width,
						text,
						isSpace: text.trim().length === 0
					});
					infoToNode.push(node);
				} else if (node.nodeType === Node.ELEMENT_NODE) {
					const el = node;
					const rect = el.getBoundingClientRect();
					const elStyle = getComputedStyle(el);
					const marginLeft = Number.parseFloat(elStyle.marginLeft) || 0;
					const marginRight = Number.parseFloat(elStyle.marginRight) || 0;
					childInfos.push({
						width: clampPositive(rect.width + marginLeft + marginRight),
						text: el.textContent ?? "",
						isSpace: false
					});
					infoToNode.push(node);
				}
				return {
					childInfos,
					fullText: childInfos.map((c) => c.text).join("")
				};
			},
			applyBreaks: (breaks) => {
				for (let i = breaks.length - 1; i >= 0; i--) {
					const breakIndex = breaks[i];
					if (breakIndex >= 0 && breakIndex < infoToNode.length) this.mainElement.insertBefore(document.createElement("br"), infoToNode[breakIndex]);
				}
			},
			needsCalibration: false
		}, wordSegmenter);
	}
	balanceNonDynamicLineBreaks(containerWidth, computedStyle, wordSegmenter) {
		const fullText = this.mainElement.textContent ?? "";
		if (fullText.trim().length === 0) return;
		this.executeLineBalance(containerWidth, {
			resetDOM: () => {
				this.mainElement.innerHTML = "";
				this.mainElement.textContent = fullText;
			},
			buildChildInfos: () => {
				const ctx = getMeasurementContext();
				if (!ctx) {
					console.debug("Canvas 2D context is not supported, skipping line balancing");
					return {
						childInfos: [],
						fullText
					};
				}
				ctx.font = `${computedStyle.fontWeight} ${computedStyle.fontSize} ${computedStyle.fontFamily}`;
				if ("letterSpacing" in ctx) ctx.letterSpacing = computedStyle.letterSpacing !== "normal" ? computedStyle.letterSpacing : "0px";
				if ("wordSpacing" in ctx) ctx.wordSpacing = computedStyle.wordSpacing !== "normal" ? computedStyle.wordSpacing : "0px";
				const childInfos = [];
				for (const { segment } of wordSegmenter.segment(fullText)) childInfos.push({
					width: ctx.measureText(segment).width,
					text: segment,
					isSpace: segment.trim().length === 0
				});
				return {
					childInfos,
					fullText
				};
			},
			applyBreaks: (breaks, childInfos) => {
				this.mainElement.innerHTML = "";
				const breakSet = new Set(breaks);
				const fragment = document.createDocumentFragment();
				for (let i = 0; i < childInfos.length; i++) {
					if (breakSet.has(i)) fragment.appendChild(document.createElement("br"));
					fragment.appendChild(document.createTextNode(childInfos[i].text));
				}
				this.mainElement.appendChild(fragment);
			},
			needsCalibration: true
		}, wordSegmenter);
	}
};
//#endregion
//#region src/utils/lyric-split-words.ts
const SPLIT_WHITESPACE_RE = /(\s+)/;
const WHITESPACE_RE = /\s/g;
/**
* 将输入的单词重新分组，之间没有空格的单词将会组合成一个单词数组
*
* 例如输入：`["Life", " ", "is", " a", " su", "gar so", "sweet"]`
*
* 应该返回：`["Life", " ", "is", " a", [" su", "gar"], "so", "sweet"]`
* @param words 输入的单词数组
* @returns 重新分组后的单词数组
*/
function chunkAndSplitLyricWords(words) {
	const result = [];
	let currentGroup = [];
	const flushGroup = () => {
		if (currentGroup.length > 0) {
			result.push(currentGroup.length === 1 ? currentGroup[0] : [...currentGroup]);
			currentGroup = [];
		}
	};
	const processAtom = (atom) => {
		const isSpace = atom.word.trim().length === 0;
		const hasRuby = (atom.ruby?.length ?? 0) > 0;
		const isCJKChar = isCJK(atom.word);
		if (!isSpace && !hasRuby && !isCJKChar) currentGroup.push(atom);
		else {
			flushGroup();
			result.push(atom);
		}
	};
	for (const w of words) {
		const isSpace = w.word.trim().length === 0;
		const romanWord = w.romanWord ?? "";
		const obscene = w.obscene ?? false;
		const hasRuby = (w.ruby?.length ?? 0) > 0;
		if (isSpace || hasRuby) {
			processAtom({ ...w });
			continue;
		}
		const parts = w.word.split(SPLIT_WHITESPACE_RE).filter((p) => p.length > 0);
		const totalLength = w.word.replace(WHITESPACE_RE, "").length || 1;
		const timePerUnit = (w.endTime - w.startTime) / totalLength;
		let currentOffset = 0;
		for (const part of parts) {
			if (!part.trim()) {
				const startTime = w.startTime + currentOffset * timePerUnit;
				processAtom({
					word: part,
					romanWord: "",
					startTime,
					endTime: startTime,
					obscene
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
						startTime,
						endTime: startTime + timePerUnit,
						obscene
					});
					currentOffset += 1;
				}
			} else {
				const partRealLen = part.length;
				const startTime = w.startTime + currentOffset * timePerUnit;
				processAtom({
					word: part,
					romanWord,
					startTime,
					endTime: startTime + partRealLen * timePerUnit,
					obscene
				});
				currentOffset += partRealLen;
			}
		}
	}
	flushGroup();
	return result;
}
//#endregion
//#region src/utils/matrix.ts
function createMatrix4() {
	return [
		1,
		0,
		0,
		0,
		0,
		1,
		0,
		0,
		0,
		0,
		1,
		0,
		0,
		0,
		0,
		1
	];
}
function scaleMatrix4(m, scale = 1, origin = {
	x: 0,
	y: 0
}) {
	const [ox, oy] = [origin.x, origin.y];
	return [
		m[0] * scale,
		m[1] * scale,
		m[2] * scale,
		m[3],
		m[4] * scale,
		m[5] * scale,
		m[6] * scale,
		m[7],
		m[8] * scale,
		m[9] * scale,
		m[10] * scale,
		m[11],
		m[12] - ox * scale + ox,
		m[13] - oy * scale + oy,
		m[14],
		m[15]
	];
}
function matrix4ToCSS(m, fractionDigits = 4) {
	const format = (n, _) => n.toFixed(fractionDigits);
	return `matrix3d(${m.map(format).join(", ")})`;
}
//#endregion
//#region src/lyric-player/dom/lyric-line.ts
const ANIMATION_FRAME_QUANTITY = 32;
const norNum = (min, max) => (x) => clamp01((x - min) / (max - min));
const EMP_EASING_MID = .5;
const beginNum = norNum(0, EMP_EASING_MID);
const endNum = norNum(EMP_EASING_MID, 1);
const bezIn = bezier(.2, .4, .58, 1);
const bezOut = bezier(.3, 0, .58, 1);
const makeEmpEasing = (mid) => {
	return (x) => x < mid ? bezIn(beginNum(x)) : 1 - bezOut(endNum(x));
};
function generateFadeGradient(width, padding = 0, bright = "rgba(0,0,0,var(--bright-mask-alpha, 1.0))", dark = "rgba(0,0,0,var(--dark-mask-alpha, 1.0))") {
	const totalAspect = 2 + width + padding;
	const widthInTotal = width / totalAspect;
	const leftPos = (1 - widthInTotal) / 2;
	return [`linear-gradient(to right,${bright} ${leftPos * 100}%,${dark} ${(leftPos + widthInTotal) * 100}%)`, totalAspect];
}
var RawLyricLineMouseEvent = class extends MouseEvent {
	constructor(line, event) {
		super(event.type, event);
		this.line = line;
	}
};
var LyricLineEl = class extends LyricLineBase {
	element = document.createElement("div");
	splittedWords = [];
	built = false;
	lineSize = [0, 0];
	renderMode = LyricLineRenderMode.SOLID;
	currentBrightAlpha = 1;
	currentDarkAlpha = .2;
	targetBrightAlpha = 1;
	targetDarkAlpha = .2;
	/**
	* 用于平衡换行、尽量减少各行长度差异的类
	*/
	balancer;
	constructor(lyricPlayer, lyricLine = {
		words: [],
		translatedLyric: "",
		romanLyric: "",
		startTime: 0,
		endTime: 0,
		isBG: false,
		isDuet: false
	}) {
		super();
		this.lyricPlayer = lyricPlayer;
		this.lyricLine = lyricLine;
		this._prevParentEl = lyricPlayer.getElement();
		lyricPlayer.resizeObserver.observe(this.element);
		this.element.setAttribute("class", lyric_player_module_default.lyricLine);
		if (this.lyricLine.isBG) this.element.classList.add(lyric_player_module_default.lyricBgLine);
		if (this.lyricLine.isDuet) this.element.classList.add(lyric_player_module_default.lyricDuetLine);
		this.lineTransforms.posY.setPosition(window.innerHeight * 2);
		this.element.appendChild(document.createElement("div"));
		this.element.appendChild(document.createElement("div"));
		this.element.appendChild(document.createElement("div"));
		const main = this.element.children[0];
		const trans = this.element.children[1];
		const roman = this.element.children[2];
		main.setAttribute("class", lyric_player_module_default.lyricMainLine);
		trans.setAttribute("class", lyric_player_module_default.lyricSubLine);
		roman.setAttribute("class", lyric_player_module_default.lyricSubLine);
		if (LyricLineBase.wordSegmenter) this.balancer = new LineBalancer(main);
		this.rebuildStyle();
	}
	listenersMap = /* @__PURE__ */ new Map();
	onMouseEvent = (e) => {
		const wrapped = new RawLyricLineMouseEvent(this, e);
		for (const listener of this.listenersMap.get(e.type) ?? []) listener.call(this, wrapped);
		if (!this.dispatchEvent(wrapped) || wrapped.defaultPrevented) {
			e.preventDefault();
			e.stopPropagation();
			e.stopImmediatePropagation();
		}
	};
	addMouseEventListener(type, callback, options) {
		if (callback) {
			const listeners = this.listenersMap.get(type) ?? /* @__PURE__ */ new Set();
			if (listeners.size === 0) this.element.addEventListener(type, this.onMouseEvent, options);
			listeners.add(callback);
			this.listenersMap.set(type, listeners);
		}
	}
	removeMouseEventListener(type, callback, options) {
		if (callback) {
			const listeners = this.listenersMap.get(type);
			if (listeners) {
				listeners.delete(callback);
				if (listeners.size === 0) this.element.removeEventListener(type, this.onMouseEvent, options);
			}
		}
	}
	areWordsOnSameLine(word1, word2) {
		if (word1?.mainElement && word2?.mainElement) {
			const word1el = word1.mainElement;
			const word2el = word2.mainElement;
			const rect1 = word1el.getBoundingClientRect();
			const rect2 = word2el.getBoundingClientRect();
			return Math.abs(rect1.top - rect2.top) < 10;
		}
		return true;
	}
	isEnabled = false;
	async enable(maskAnimationTime = this.lyricPlayer.getCurrentTime(), shouldPlay = this.lyricPlayer.getIsPlaying()) {
		this.isEnabled = true;
		this.element.classList.add(lyric_player_module_default.active);
		const main = this.element.children[0];
		const relativeTime = clampPositive(maskAnimationTime - this.lyricLine.startTime);
		for (const word of this.splittedWords) {
			for (const a of word.elementAnimations) {
				a.currentTime = relativeTime;
				a.playbackRate = 1;
				const timing = a.effect?.getComputedTiming();
				const duration = Number(timing?.duration ?? 0);
				const endTime = Number(timing?.delay ?? 0) + duration;
				if (shouldPlay && relativeTime < endTime) a.play();
				else a.pause();
			}
			for (const a of word.maskAnimations) {
				const t = Math.min(this.totalDuration, relativeTime);
				a.currentTime = t;
				a.playbackRate = 1;
				const timing = a.effect?.getComputedTiming();
				const duration = Number(timing?.duration ?? 0);
				const endTime = Number(timing?.delay ?? 0) + duration;
				if (shouldPlay && t < endTime) a.play();
				else a.pause();
			}
		}
		main.classList.add(lyric_player_module_default.active);
	}
	disable() {
		this.isEnabled = false;
		this.element.classList.remove(lyric_player_module_default.active);
		this.renderMode = LyricLineRenderMode.SOLID;
		const main = this.element.children[0];
		for (const word of this.splittedWords) {
			for (const a of word.elementAnimations) if (a.id === "float-word" || a.id.includes("emphasize-word-float-only")) {
				a.playbackRate = -1;
				a.play();
			}
			for (const a of word.maskAnimations) a.pause();
		}
		main.classList.remove(lyric_player_module_default.active);
	}
	lastWord;
	async resume() {
		if (!this.isEnabled) return;
		for (const word of this.splittedWords) {
			for (const a of word.elementAnimations) if (!this.lastWord || this.splittedWords.indexOf(this.lastWord) < this.splittedWords.indexOf(word)) {
				const timing = a.effect?.getComputedTiming();
				const duration = timing?.duration || 0;
				const endTime = (timing?.delay || 0) + duration;
				const currentTime = a.currentTime || 0;
				if (a.playState !== "finished" && currentTime < endTime) a.play();
			}
			for (const a of word.maskAnimations) if (!this.lastWord || this.splittedWords.indexOf(this.lastWord) < this.splittedWords.indexOf(word)) {
				const timing = a.effect?.getComputedTiming();
				const duration = timing?.duration || 0;
				const endTime = (timing?.delay || 0) + duration;
				const currentTime = a.currentTime || 0;
				if (a.playState !== "finished" && currentTime < endTime) a.play();
			}
		}
	}
	async pause() {
		if (!this.isEnabled) return;
		for (const word of this.splittedWords) {
			for (const a of word.elementAnimations) a.pause();
			for (const a of word.maskAnimations) a.pause();
		}
	}
	setMaskAnimationState(maskAnimationTime = 0) {
		const t = maskAnimationTime - this.lyricLine.startTime;
		for (const word of this.splittedWords) for (const a of word.maskAnimations) {
			a.currentTime = clamp(t, 0, this.totalDuration);
			a.playbackRate = 1;
			if (t >= 0 && t < this.totalDuration) a.play();
			else a.pause();
		}
	}
	getLine() {
		return this.lyricLine;
	}
	_prevParentEl;
	lastStyle = "";
	show() {
		if (!this.element.parentElement) {
			this._prevParentEl.appendChild(this.element);
			this.lyricPlayer.resizeObserver.observe(this.element);
		}
		if (!this.built) {
			this.rebuildElement();
			this.built = true;
			this.updateMaskImageSync();
		}
		this.rebuildStyle();
	}
	hide() {
		if (this.element.parentElement) {
			this._prevParentEl.removeChild(this.element);
			this.lyricPlayer.resizeObserver.unobserve(this.element);
		}
		if (this.built) {
			this.disposeElements();
			this.built = false;
		}
	}
	rebuildStyle() {
		let style = "";
		style += `transform:translateY(${this.lineTransforms.posY.getCurrentPosition().toFixed(1)}px) scale(${(this.lineTransforms.scale.getCurrentPosition() / 100).toFixed(4)});`;
		if (!this.lyricPlayer.getEnableSpring() && this.isInSight) style += `transition-delay:${this.delay}ms;`;
		style += `filter:blur(${Math.min(5, this.blur)}px);`;
		if (style !== this.lastStyle) {
			this.lastStyle = style;
			this.element.setAttribute("style", style);
		}
	}
	rebuildElement() {
		this.disposeElements();
		const main = this.element.children[0];
		const trans = this.element.children[1];
		const roman = this.element.children[2];
		if (this.lyricPlayer._getIsNonDynamic()) {
			main.innerText = this.lyricLine.words.map((w) => this.lyricPlayer.processObsceneWord(w)).join("");
			this.setSubLinesText(trans, roman);
			return;
		}
		const chunkedWords = chunkAndSplitLyricWords(this.lyricLine.words);
		const hasRubyLine = this.lyricLine.words.some((word) => (word.ruby?.length ?? 0) > 0);
		const hasRomanLine = this.lyricLine.words.some((word) => (word.romanWord?.trim().length ?? 0) > 0);
		main.innerHTML = "";
		for (const chunk of chunkedWords) this.buildWord(chunk, main, hasRubyLine, hasRomanLine);
		this.setSubLinesText(trans, roman);
	}
	/** 设置翻译与音译行文本 */
	setSubLinesText(trans, roman) {
		trans.innerText = this.lyricLine.translatedLyric;
		roman.innerText = this.lyricLine.romanLyric;
	}
	getRubyCharCount(word) {
		return (word.ruby ?? []).reduce((total, ruby) => total + ruby.word.length, 0);
	}
	getRubySegments(word) {
		return (word.ruby ?? []).filter((ruby) => (ruby?.word?.trim().length ?? 0) > 0);
	}
	createWord(word, shouldEmphasize, hasRubyLine, hasRomanLine) {
		const mainWordEl = document.createElement("span");
		const subElements = [];
		const romanWord = word.romanWord?.trim() ?? "";
		const wordContainer = hasRubyLine ? document.createElement("div") : mainWordEl;
		if (hasRubyLine) {
			const rubyWordEl = document.createElement("div");
			const rubySegments = this.getRubySegments(word);
			for (const ruby of rubySegments) {
				const rubyPartEl = document.createElement("span");
				rubyPartEl.innerText = ruby.word;
				rubyPartEl.dataset.startTime = String(ruby.startTime);
				rubyPartEl.dataset.endTime = String(ruby.endTime);
				rubyWordEl.appendChild(rubyPartEl);
			}
			rubyWordEl.classList.add(lyric_player_module_default.rubyWord);
			mainWordEl.classList.add(lyric_player_module_default.wordWithRuby);
			wordContainer.classList.add(lyric_player_module_default.wordBody);
			mainWordEl.appendChild(rubyWordEl);
			mainWordEl.appendChild(wordContainer);
		}
		const displayWord = this.lyricPlayer.processObsceneWord(word);
		if (shouldEmphasize) {
			mainWordEl.classList.add(lyric_player_module_default.emphasize);
			const trimmedWord = displayWord.trim();
			if (LyricLineBase.graphemeSegmenter) for (const { segment } of LyricLineBase.graphemeSegmenter.segment(trimmedWord)) {
				const charEl = document.createElement("span");
				charEl.innerText = segment;
				subElements.push(charEl);
				wordContainer.appendChild(charEl);
			}
			else for (const segment of Array.from(trimmedWord)) {
				const charEl = document.createElement("span");
				charEl.innerText = segment;
				subElements.push(charEl);
				wordContainer.appendChild(charEl);
			}
		} else if (hasRomanLine) {
			const wordEl = document.createElement("div");
			wordEl.innerText = displayWord.trim();
			wordContainer.appendChild(wordEl);
		} else if (romanWord.length === 0) wordContainer.innerText = displayWord.trim();
		if (hasRomanLine) {
			const romanWordEl = document.createElement("div");
			romanWordEl.innerText = romanWord.length > 0 ? romanWord : "\xA0";
			romanWordEl.classList.add(lyric_player_module_default.romanWord);
			wordContainer.appendChild(romanWordEl);
		}
		return {
			...word,
			mainElement: mainWordEl,
			subElements,
			elementAnimations: [this.initFloatAnimation(word, mainWordEl)],
			maskAnimations: [],
			width: 0,
			height: 0,
			padding: 0,
			shouldEmphasize
		};
	}
	buildWord(input, main, hasRubyLine, hasRomanLine) {
		const chunk = Array.isArray(input) ? input : [input];
		if (chunk.length === 0) return;
		if (chunk.every((w) => !w.word.trim())) {
			const textContent = chunk.map((w) => w.word).join("");
			main.appendChild(document.createTextNode(textContent));
			return;
		}
		const merged = chunk.reduce((a, b) => {
			a.endTime = Math.max(a.endTime, b.endTime);
			a.startTime = Math.min(a.startTime, b.startTime);
			a.word += b.word;
			return a;
		}, {
			word: "",
			romanWord: "",
			startTime: Number.POSITIVE_INFINITY,
			endTime: Number.NEGATIVE_INFINITY,
			wordType: "normal",
			obscene: false
		});
		let emp = chunk.some((word) => LyricLineBase.shouldEmphasize(word));
		if (!isCJK(merged.word)) emp = emp || LyricLineBase.shouldEmphasize(merged);
		const wrapperWordEl = document.createElement("span");
		wrapperWordEl.classList.add(lyric_player_module_default.emphasizeWrapper);
		const characterElements = [];
		for (const word of chunk) {
			if (!word.word.trim()) {
				wrapperWordEl.appendChild(document.createTextNode(word.word));
				continue;
			}
			const realWord = this.createWord(word, emp, hasRubyLine, hasRomanLine);
			if (emp) characterElements.push(...realWord.subElements);
			this.splittedWords.push(realWord);
			wrapperWordEl.appendChild(realWord.mainElement);
		}
		if (emp && this.splittedWords.length > 0) {
			const lastWordOfChunk = this.splittedWords[this.splittedWords.length - 1];
			const rubyCharCount = chunk.reduce((total, word) => total + this.getRubyCharCount(word), 0);
			lastWordOfChunk.elementAnimations.push(...this.initEmphasizeAnimation(merged, characterElements, merged.endTime - merged.startTime, merged.startTime - this.lyricLine.startTime, rubyCharCount));
		}
		main.appendChild(wrapperWordEl);
	}
	initFloatAnimation(word, wordEl) {
		const delay = word.startTime - this.lyricLine.startTime;
		const duration = Math.max(1e3, word.endTime - word.startTime);
		let up = .05;
		if (this.lyricLine.isBG) up *= 2;
		const a = wordEl.animate([{ transform: "translateY(0px)" }, { transform: `translateY(${-up}em)` }], {
			duration: Number.isFinite(duration) ? duration : 0,
			delay: Number.isFinite(delay) ? delay : 0,
			id: "float-word",
			composite: "add",
			fill: "both",
			easing: "ease-out"
		});
		a.pause();
		return a;
	}
	initEmphasizeAnimation(word, characterElements, duration, delay, rubyCharCount) {
		const de = clampPositive(delay);
		let du = Math.max(1e3, duration);
		const anchorCharCount = rubyCharCount > 0 ? rubyCharCount : Math.max(1, characterElements.length);
		let result = [];
		let amount = du / 2e3;
		amount = amount > 1 ? Math.sqrt(amount) : amount ** 3;
		let blur = du / 3e3;
		blur = blur > 1 ? Math.sqrt(blur) : blur ** 3;
		amount *= .6;
		blur *= .5;
		if (this.lyricLine.words.length > 0 && word.word.includes(this.lyricLine.words[this.lyricLine.words.length - 1].word)) {
			amount *= 1.6;
			blur *= 1.5;
			du *= 1.2;
		}
		amount = Math.min(1.2, amount);
		blur = Math.min(.8, blur);
		const animateDu = Number.isFinite(du) ? du : 0;
		const empEasing = makeEmpEasing(EMP_EASING_MID);
		result = characterElements.flatMap((el, i, arr) => {
			const wordDe = de + du / 2.5 / anchorCharCount * i;
			const result = [];
			const frames = new Array(ANIMATION_FRAME_QUANTITY).fill(0).map((_, j) => {
				const x = (j + 1) / ANIMATION_FRAME_QUANTITY;
				const transX = empEasing(x);
				const glowLevel = empEasing(x) * blur;
				const mat = scaleMatrix4(createMatrix4(), 1 + transX * .1 * amount);
				const offsetX = -transX * .03 * amount * (arr.length / 2 - i);
				const offsetY = -transX * .025 * amount;
				return {
					offset: x,
					transform: `${matrix4ToCSS(mat, 4)} translate(${offsetX}em, ${offsetY}em)`,
					textShadow: `0 0 ${Math.min(.3, blur * .3)}em rgba(255, 255, 255, ${glowLevel})`
				};
			});
			const glow = el.animate(frames, {
				duration: animateDu,
				delay: Number.isFinite(wordDe) ? wordDe : 0,
				id: `emphasize-word-${el.innerText}-${i}`,
				iterations: 1,
				composite: "replace",
				fill: "both"
			});
			glow.onfinish = () => {
				glow.pause();
			};
			glow.pause();
			result.push(glow);
			const floatFrame = new Array(ANIMATION_FRAME_QUANTITY).fill(0).map((_, j) => {
				const x = (j + 1) / ANIMATION_FRAME_QUANTITY;
				let y = Math.sin(x * Math.PI);
				if (this.lyricLine.isBG) y *= 2;
				return {
					offset: x,
					transform: `translateY(${-y * .05}em)`
				};
			});
			const float = el.animate(floatFrame, {
				duration: animateDu * 1.4,
				delay: Number.isFinite(wordDe) ? wordDe - 400 : 0,
				id: "emphasize-word-float",
				iterations: 1,
				composite: "add",
				fill: "both"
			});
			float.onfinish = () => {
				float.pause();
			};
			float.pause();
			result.push(float);
			return result;
		});
		return result;
	}
	get totalDuration() {
		return this.lyricLine.endTime - this.lyricLine.startTime;
	}
	onLineSizeChange(_size) {
		this.updateMaskImageSync();
	}
	updateMaskImageSync() {
		for (const word of this.splittedWords) {
			const el = word.mainElement;
			if (el) {
				word.padding = Number.parseFloat(getComputedStyle(el).paddingLeft);
				word.width = el.clientWidth - word.padding * 2;
				word.height = el.clientHeight - word.padding * 2;
			} else {
				word.width = 0;
				word.height = 0;
				word.padding = 0;
			}
		}
		if (this.balancer && LyricLineBase.wordSegmenter) this.balancer.balanceLineBreaks(this.lyricPlayer._getIsNonDynamic(), this.splittedWords.length > 0, LyricLineBase.wordSegmenter);
		if (this.lyricPlayer.supportMaskImage) this.generateWebAnimationBasedMaskImage();
		else this.generateCalcBasedMaskImage();
		if (this.isEnabled) {
			const isPlayerRunning = this.lyricPlayer.getIsPlaying?.() ?? true;
			this.enable(this.lyricPlayer.getCurrentTime(), isPlayerRunning);
		}
	}
	generateCalcBasedMaskImage() {
		for (const word of this.splittedWords) {
			const wordEl = word.mainElement;
			if (wordEl) {
				word.width = wordEl.clientWidth;
				word.height = wordEl.clientHeight;
				const fadeWidth = word.height * this.lyricPlayer.getWordFadeWidth();
				const [maskImage, totalAspect] = generateFadeGradient(fadeWidth / word.width);
				const totalAspectStr = `${totalAspect * 100}% 100%`;
				if (this.lyricPlayer.supportMaskImage) {
					wordEl.style.maskImage = maskImage;
					wordEl.style.maskRepeat = "no-repeat";
					wordEl.style.maskOrigin = "left";
					wordEl.style.maskSize = totalAspectStr;
				} else {
					wordEl.style.webkitMaskImage = maskImage;
					wordEl.style.webkitMaskRepeat = "no-repeat";
					wordEl.style.webkitMaskOrigin = "left";
					wordEl.style.webkitMaskSize = totalAspectStr;
				}
				const w = word.width + fadeWidth;
				const maskPos = `clamp(${-w}px,calc(${-w}px + (var(--amll-player-time) - ${word.startTime})*${w / Math.abs(word.endTime - word.startTime)}px),0px) 0px, left top`;
				wordEl.style.maskPosition = maskPos;
				wordEl.style.webkitMaskPosition = maskPos;
			}
		}
	}
	generateWebAnimationBasedMaskImage() {
		const totalFadeDuration = Math.max(0, ...this.splittedWords.map((w) => w.endTime), this.lyricLine.endTime) - this.lyricLine.startTime;
		this.splittedWords.forEach((word, i) => {
			const wordEl = word.mainElement;
			if (wordEl) {
				const fadeWidth = word.height * this.lyricPlayer.getWordFadeWidth();
				const [maskImage, totalAspect] = generateFadeGradient(fadeWidth / (word.width + word.padding * 2));
				const totalAspectStr = `${totalAspect * 100}% 100%`;
				if (this.lyricPlayer.supportMaskImage) {
					wordEl.style.maskImage = maskImage;
					wordEl.style.maskRepeat = "no-repeat";
					wordEl.style.maskOrigin = "left";
					wordEl.style.maskSize = totalAspectStr;
				} else {
					wordEl.style.webkitMaskImage = maskImage;
					wordEl.style.webkitMaskRepeat = "no-repeat";
					wordEl.style.webkitMaskOrigin = "left";
					wordEl.style.webkitMaskSize = totalAspectStr;
				}
				const widthBeforeSelf = this.splittedWords.slice(0, i).reduce((a, b) => a + b.width, 0) + (this.splittedWords[0] ? fadeWidth : 0);
				const minOffset = -(word.width + word.padding * 2 + fadeWidth);
				const clampOffset = (x) => clamp(x, minOffset, 0);
				let curPos = -widthBeforeSelf - word.width - word.padding - fadeWidth;
				let timeOffset = 0;
				const frames = [];
				let lastPos = curPos;
				let lastTime = 0;
				const pushFrame = () => {
					const moveOffset = curPos - lastPos;
					const time = clamp01(timeOffset);
					const duration = time - lastTime;
					const d = Math.abs(duration / moveOffset);
					if (curPos > minOffset && lastPos < minOffset) {
						const staticTime = Math.abs(lastPos - minOffset) * d;
						const value = `${clampOffset(lastPos)}px 0`;
						const frame = {
							offset: lastTime + staticTime,
							maskPosition: value
						};
						frames.push(frame);
					}
					if (curPos > 0 && lastPos < 0) {
						const staticTime = Math.abs(lastPos) * d;
						const value = `${clampOffset(curPos)}px 0`;
						const frame = {
							offset: lastTime + staticTime,
							maskPosition: value
						};
						frames.push(frame);
					}
					const frame = {
						offset: time,
						maskPosition: `${clampOffset(curPos)}px 0`
					};
					frames.push(frame);
					lastPos = curPos;
					lastTime = time;
				};
				pushFrame();
				let lastTimeStamp = 0;
				this.splittedWords.forEach((otherWord, j) => {
					{
						const curTimeStamp = otherWord.startTime - this.lyricLine.startTime;
						const staticDuration = curTimeStamp - lastTimeStamp;
						timeOffset += staticDuration / totalFadeDuration;
						if (staticDuration > 0) pushFrame();
						lastTimeStamp = curTimeStamp;
					}
					{
						const fadeDuration = clampPositive(otherWord.endTime - otherWord.startTime);
						const rubySegments = this.getRubySegments(otherWord);
						const rubyCharCount = rubySegments.reduce((total, ruby) => total + ruby.word.length, 0);
						if (rubyCharCount > 0) {
							const widthPerChar = otherWord.width / rubyCharCount;
							let charIndex = 0;
							for (const ruby of rubySegments) {
								const rubyStartTime = Number.isFinite(ruby.startTime) ? ruby.startTime : otherWord.startTime;
								const rubyEndTime = Number.isFinite(ruby.endTime) ? ruby.endTime : otherWord.endTime;
								const rubyStart = Math.max(rubyStartTime, otherWord.startTime);
								const rubyEnd = Math.min(Math.max(rubyEndTime, rubyStart), otherWord.endTime);
								const rubyStartStamp = rubyStart - this.lyricLine.startTime;
								const rubyStaticDuration = rubyStartStamp - lastTimeStamp;
								timeOffset += rubyStaticDuration / totalFadeDuration;
								if (rubyStaticDuration > 0) pushFrame();
								lastTimeStamp = rubyStartStamp;
								const perCharDuration = clampPositive(rubyEnd - rubyStart) / ruby.word.length;
								for (let rubyCharIndex = 0; rubyCharIndex < ruby.word.length; rubyCharIndex++) {
									timeOffset += perCharDuration / totalFadeDuration;
									curPos += widthPerChar;
									if (j === 0 && charIndex === 0) curPos += fadeWidth * 1.5;
									if (j === this.splittedWords.length - 1 && charIndex === rubyCharCount - 1) curPos += fadeWidth * .5;
									if (perCharDuration > 0) pushFrame();
									lastTimeStamp += perCharDuration;
									charIndex++;
								}
							}
							const wordEndStamp = Math.max(otherWord.endTime - this.lyricLine.startTime, lastTimeStamp);
							const wordTailDuration = wordEndStamp - lastTimeStamp;
							timeOffset += wordTailDuration / totalFadeDuration;
							if (wordTailDuration > 0) pushFrame();
							lastTimeStamp = wordEndStamp;
						} else {
							const segmentCount = 1;
							const segmentWidth = otherWord.width / segmentCount;
							const segmentDuration = fadeDuration / segmentCount;
							for (let segmentIndex = 0; segmentIndex < segmentCount; segmentIndex++) {
								timeOffset += segmentDuration / totalFadeDuration;
								curPos += segmentWidth;
								if (j === 0 && segmentIndex === 0) curPos += fadeWidth * 1.5;
								if (j === this.splittedWords.length - 1 && segmentIndex === segmentCount - 1) curPos += fadeWidth * .5;
								if (segmentDuration > 0) pushFrame();
								lastTimeStamp += segmentDuration;
							}
						}
					}
				});
				for (const a of word.maskAnimations) a.cancel();
				try {
					const ani = wordEl.animate(frames, {
						duration: totalFadeDuration || 1,
						id: `fade-word-${word.word}-${i}`,
						fill: "both"
					});
					ani.pause();
					word.maskAnimations = [ani];
				} catch (err) {
					console.warn("应用渐变动画发生错误", frames, totalFadeDuration, err);
				}
			}
		});
	}
	getElement() {
		return this.element;
	}
	updateMaskAlphaTargets(scale) {
		const factor = clamp01((scale - .97) / .03);
		const dynamicDarkAlpha = factor * .2 + .2;
		const dynamicBrightAlpha = factor * .8 + .2;
		if (this.renderMode === LyricLineRenderMode.SOLID) {
			this.targetBrightAlpha = dynamicDarkAlpha;
			this.targetDarkAlpha = dynamicDarkAlpha;
		} else {
			this.targetBrightAlpha = dynamicBrightAlpha;
			this.targetDarkAlpha = dynamicDarkAlpha;
		}
	}
	applyAlphaToDom(delta) {
		const dt = delta || .016;
		const ATTACK_SPEED = 50;
		const RELEASE_SPEED = 7;
		const getFactor = (speed) => 1 - Math.exp(-speed * dt);
		const brightFactor = getFactor(this.targetBrightAlpha > this.currentBrightAlpha ? ATTACK_SPEED : RELEASE_SPEED);
		if (Math.abs(this.targetBrightAlpha - this.currentBrightAlpha) < .001) this.currentBrightAlpha = this.targetBrightAlpha;
		else this.currentBrightAlpha += (this.targetBrightAlpha - this.currentBrightAlpha) * brightFactor;
		const darkFactor = getFactor(this.targetDarkAlpha > this.currentDarkAlpha ? ATTACK_SPEED : RELEASE_SPEED);
		if (Math.abs(this.targetDarkAlpha - this.currentDarkAlpha) < .001) this.currentDarkAlpha = this.targetDarkAlpha;
		else this.currentDarkAlpha += (this.targetDarkAlpha - this.currentDarkAlpha) * darkFactor;
		this.element.style.setProperty("--bright-mask-alpha", this.currentBrightAlpha.toFixed(3));
		this.element.style.setProperty("--dark-mask-alpha", this.currentDarkAlpha.toFixed(3));
	}
	setTransform(top = this.top, scale = this.scale, opacity = 1, blur = 0, force = false, delay = 0, mode = LyricLineRenderMode.SOLID) {
		super.setTransform(top, scale, opacity, blur, force, delay);
		this.renderMode = mode;
		const beforeInSight = this.isInSight;
		const enableSpring = this.lyricPlayer.getEnableSpring();
		this.top = top;
		this.scale = scale;
		this.delay = delay * 1e3 | 0;
		const main = this.element.children[0];
		main.style.opacity = `${opacity}`;
		if (force || !enableSpring) {
			this.blur = Math.min(32, blur);
			this.lineTransforms.posY.setPosition(top);
			this.lineTransforms.scale.setPosition(scale);
			if (!enableSpring) {
				const afterInSight = this.isInSight;
				if (beforeInSight || afterInSight) this.show();
				else this.hide();
			} else this.rebuildStyle();
			const currentScale = this.lineTransforms.scale.getCurrentPosition();
			this.updateMaskAlphaTargets(currentScale / 100);
			this.currentBrightAlpha = this.targetBrightAlpha;
			this.currentDarkAlpha = this.targetDarkAlpha;
			this.element.style.setProperty("--bright-mask-alpha", String(this.currentBrightAlpha));
			this.element.style.setProperty("--dark-mask-alpha", String(this.currentDarkAlpha));
		} else {
			this.lineTransforms.posY.setTargetPosition(top, delay);
			this.lineTransforms.scale.setTargetPosition(scale);
			if (this.blur !== Math.min(5, blur)) {
				this.blur = Math.min(5, blur);
				const roundedBlur = blur.toFixed(3);
				this.element.style.filter = `blur(${roundedBlur}px)`;
			}
		}
	}
	update(delta = 0) {
		if (!this.lyricPlayer.getEnableSpring()) return;
		this.lineTransforms.posY.update(delta);
		this.lineTransforms.scale.update(delta);
		if (this.isInSight) this.show();
		else this.hide();
		const currentScale = this.lineTransforms.scale.getCurrentPosition() / 100;
		this.updateMaskAlphaTargets(currentScale);
		this.applyAlphaToDom(delta);
	}
	_getDebugTargetPos() {
		return `[位移: ${this.top}; 缩放: ${this.scale}; 延时: ${this.delay}]`;
	}
	get isInSight() {
		const t = this.lineTransforms.posY.getCurrentPosition();
		const h = this.lyricPlayer.lyricLinesSize.get(this)?.[1] ?? 0;
		const b = t + h;
		const pb = this.lyricPlayer.size[1];
		const ov = this.lyricPlayer.getOverscanPx();
		return !(t > pb + h + ov || b < -h - ov);
	}
	disposeElements() {
		this.balancer?.reset();
		for (const realWord of this.splittedWords) {
			for (const a of realWord.elementAnimations) a.cancel();
			for (const a of realWord.maskAnimations) a.cancel();
			for (const sub of realWord.subElements) {
				sub.remove();
				sub.parentNode?.removeChild(sub);
			}
			realWord.elementAnimations = [];
			realWord.maskAnimations = [];
			realWord.subElements = [];
			if (realWord.mainElement?.parentNode) realWord.mainElement.parentNode.removeChild(realWord.mainElement);
		}
		this.splittedWords = [];
		const main = this.element.children[0];
		const trans = this.element.children[1];
		const roman = this.element.children[2];
		if (main) main.innerHTML = "";
		if (trans) trans.innerHTML = "";
		if (roman) roman.innerHTML = "";
	}
	dispose() {
		this.disposeElements();
		this.lyricPlayer.resizeObserver.unobserve(this.element);
		this.element.remove();
	}
};
//#endregion
//#region src/lyric-player/dom/index.ts
/**
* 歌词行鼠标相关事件，可以获取到歌词行的索引和歌词行元素
*/
var LyricLineMouseEvent = class extends MouseEvent {
	constructor(lineIndex, line, event) {
		super(`line-${event.type}`, event);
		this.lineIndex = lineIndex;
		this.line = line;
	}
};
/**
* 歌词播放组件，本框架的核心组件
*
* 尽可能贴切 Apple Music for iPad 的歌词效果设计，且做了力所能及的优化措施
*/
var DomLyricPlayer = class extends LyricPlayerBase {
	currentLyricLineObjects = [];
	onResize() {
		const computedStyles = getComputedStyle(this.element);
		this._baseFontSize = Number.parseFloat(computedStyles.fontSize);
		this.rebuildStyle();
	}
	supportPlusLighter = CSS.supports("mix-blend-mode", "plus-lighter");
	supportMaskImage = CSS.supports("mask-image", "none");
	innerSize = [0, 0];
	onLineClickedHandler = (e) => {
		const evt = new LyricLineMouseEvent(this.lyricLinesIndexes.get(e.line) ?? -1, e.line, e);
		if (!this.dispatchEvent(evt)) {
			e.preventDefault();
			e.stopPropagation();
			e.stopImmediatePropagation();
		}
	};
	/**
	* 是否为非逐词歌词
	* @internal
	*/
	_getIsNonDynamic() {
		return this.isNonDynamic;
	}
	_baseFontSize = Number.parseFloat(getComputedStyle(this.element).fontSize);
	get baseFontSize() {
		return this._baseFontSize;
	}
	constructor() {
		super();
		this.onResize();
		this.element.classList.add("amll-lyric-player", "dom");
		if (this.disableSpring) this.element.classList.add(lyric_player_module_default.disableSpring);
	}
	rebuildStyle() {}
	setWordFadeWidth(value = .5) {
		super.setWordFadeWidth(value);
		for (const el of this.currentLyricLineObjects) el.updateMaskImageSync();
	}
	/**
	* 设置当前播放歌词，要注意传入后这个数组内的信息不得修改，否则会发生错误
	* @param lines 歌词数组
	* @param initialTime 初始时间，默认为 0
	*/
	setLyricLines(lines, initialTime = 0) {
		super.setLyricLines(lines, initialTime);
		if (this.hasDuetLine) this.element.classList.add(lyric_player_module_default.hasDuetLine);
		else this.element.classList.remove(lyric_player_module_default.hasDuetLine);
		if (!this.supportMaskImage) this.element.style.setProperty("--amll-player-time", `${initialTime}`);
		for (const line of this.currentLyricLineObjects) {
			line.removeMouseEventListener("click", this.onLineClickedHandler);
			line.removeMouseEventListener("contextmenu", this.onLineClickedHandler);
			line.dispose();
		}
		this.currentLyricLineObjects = this.processedLines.map((line, i) => {
			const lineEl = new LyricLineEl(this, line);
			lineEl.addMouseEventListener("click", this.onLineClickedHandler);
			lineEl.addMouseEventListener("contextmenu", this.onLineClickedHandler);
			this.lyricLinesIndexes.set(lineEl, i);
			this.lyricLineElementMap.set(lineEl.getElement(), lineEl);
			return lineEl;
		});
		this.setLinePosXSpringParams({});
		this.setLinePosYSpringParams({});
		this.setLineScaleSpringParams({});
		this.calcLayout(true);
		this.update(0);
	}
	pause() {
		super.pause();
		this.element.classList.remove("playing");
		this.interludeDots.pause();
		for (const line of this.currentLyricLineObjects) line.pause();
	}
	resume() {
		super.resume();
		this.element.classList.add("playing");
		this.interludeDots.resume();
		for (const line of this.currentLyricLineObjects) line.resume();
	}
	update(delta = 0) {
		if (!this.timelineState.initialLayoutFinished) return;
		super.update(delta);
		if (!this.supportMaskImage) this.element.style.setProperty("--amll-player-time", `${this.timelineState.currentTime}`);
		if (!this.isPageVisible) return;
		const deltaS = delta / 1e3;
		for (const line of this.currentLyricLineObjects) line.update(deltaS);
	}
	dispose() {
		super.dispose();
		this.element.remove();
		for (const el of this.currentLyricLineObjects) el.dispose();
		this.bottomLine.dispose();
		this.interludeDots.dispose();
	}
};
//#endregion
export { DomLyricPlayer, DomLyricPlayer as LyricPlayer, LayoutAlignAnchor, LyricLineMouseEvent, LyricLineRenderMode, LyricPlayerBase, MaskObsceneWordsMode };

//# sourceMappingURL=amll-core.mjs.map