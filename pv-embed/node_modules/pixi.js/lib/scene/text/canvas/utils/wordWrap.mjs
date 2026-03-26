import { collapseSpaces, collapseNewlines, tokenize, isNewline, trimRight, isBreakingSpace, getCharacterGroups } from './textTokenization.mjs';

"use strict";
const contextSettings = {
  // TextMetrics requires getImageData readback for measuring fonts.
  willReadFrequently: true
};
function getFromCache(key, letterSpacing, cache, context, measureTextFn) {
  let width = cache[key];
  if (typeof width !== "number") {
    width = measureTextFn(key, letterSpacing, context) + letterSpacing;
    cache[key] = width;
  }
  return width;
}
function wordWrap(text, style, canvas, measureTextFn, canBreakWordsFn, canBreakCharsFn, wordWrapSplitFn) {
  const context = canvas.getContext("2d", contextSettings);
  context.font = style._fontString;
  let width = 0;
  let line = "";
  const linesArray = [];
  const cache = /* @__PURE__ */ Object.create(null);
  const { letterSpacing, whiteSpace } = style;
  const shouldCollapseSpaces = collapseSpaces(whiteSpace);
  const shouldCollapseNewlines = collapseNewlines(whiteSpace);
  let canPrependSpaces = !shouldCollapseSpaces;
  const wordWrapWidth = style.wordWrapWidth + letterSpacing;
  const tokens = tokenize(text);
  for (let i = 0; i < tokens.length; i++) {
    let token = tokens[i];
    if (isNewline(token)) {
      if (!shouldCollapseNewlines) {
        linesArray.push(trimRight(line));
        canPrependSpaces = !shouldCollapseSpaces;
        line = "";
        width = 0;
        continue;
      }
      token = " ";
    }
    if (shouldCollapseSpaces) {
      const currIsBreakingSpace = isBreakingSpace(token);
      const lastIsBreakingSpace = isBreakingSpace(line[line.length - 1]);
      if (currIsBreakingSpace && lastIsBreakingSpace) {
        continue;
      }
    }
    const tokenWidth = getFromCache(token, letterSpacing, cache, context, measureTextFn);
    if (tokenWidth > wordWrapWidth) {
      if (line !== "") {
        linesArray.push(trimRight(line));
        line = "";
        width = 0;
      }
      if (canBreakWordsFn(token, style.breakWords)) {
        const charGroups = getCharacterGroups(token, style.breakWords, wordWrapSplitFn, canBreakCharsFn);
        for (const char of charGroups) {
          const characterWidth = getFromCache(char, letterSpacing, cache, context, measureTextFn);
          if (characterWidth + width > wordWrapWidth) {
            linesArray.push(trimRight(line));
            canPrependSpaces = false;
            line = "";
            width = 0;
          }
          line += char;
          width += characterWidth;
        }
      } else {
        if (line.length > 0) {
          linesArray.push(trimRight(line));
          line = "";
          width = 0;
        }
        linesArray.push(trimRight(token));
        canPrependSpaces = false;
        line = "";
        width = 0;
      }
    } else {
      if (tokenWidth + width > wordWrapWidth) {
        canPrependSpaces = false;
        linesArray.push(trimRight(line));
        line = "";
        width = 0;
      }
      if (line.length > 0 || !isBreakingSpace(token) || canPrependSpaces) {
        line += token;
        width += tokenWidth;
      }
    }
  }
  const trimmedLine = trimRight(line);
  if (trimmedLine.length > 0) {
    linesArray.push(trimmedLine);
  }
  return linesArray.join("\n");
}

export { wordWrap };
//# sourceMappingURL=wordWrap.mjs.map
