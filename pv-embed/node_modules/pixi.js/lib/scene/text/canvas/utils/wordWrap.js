'use strict';

var textTokenization = require('./textTokenization.js');

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
  const shouldCollapseSpaces = textTokenization.collapseSpaces(whiteSpace);
  const shouldCollapseNewlines = textTokenization.collapseNewlines(whiteSpace);
  let canPrependSpaces = !shouldCollapseSpaces;
  const wordWrapWidth = style.wordWrapWidth + letterSpacing;
  const tokens = textTokenization.tokenize(text);
  for (let i = 0; i < tokens.length; i++) {
    let token = tokens[i];
    if (textTokenization.isNewline(token)) {
      if (!shouldCollapseNewlines) {
        linesArray.push(textTokenization.trimRight(line));
        canPrependSpaces = !shouldCollapseSpaces;
        line = "";
        width = 0;
        continue;
      }
      token = " ";
    }
    if (shouldCollapseSpaces) {
      const currIsBreakingSpace = textTokenization.isBreakingSpace(token);
      const lastIsBreakingSpace = textTokenization.isBreakingSpace(line[line.length - 1]);
      if (currIsBreakingSpace && lastIsBreakingSpace) {
        continue;
      }
    }
    const tokenWidth = getFromCache(token, letterSpacing, cache, context, measureTextFn);
    if (tokenWidth > wordWrapWidth) {
      if (line !== "") {
        linesArray.push(textTokenization.trimRight(line));
        line = "";
        width = 0;
      }
      if (canBreakWordsFn(token, style.breakWords)) {
        const charGroups = textTokenization.getCharacterGroups(token, style.breakWords, wordWrapSplitFn, canBreakCharsFn);
        for (const char of charGroups) {
          const characterWidth = getFromCache(char, letterSpacing, cache, context, measureTextFn);
          if (characterWidth + width > wordWrapWidth) {
            linesArray.push(textTokenization.trimRight(line));
            canPrependSpaces = false;
            line = "";
            width = 0;
          }
          line += char;
          width += characterWidth;
        }
      } else {
        if (line.length > 0) {
          linesArray.push(textTokenization.trimRight(line));
          line = "";
          width = 0;
        }
        linesArray.push(textTokenization.trimRight(token));
        canPrependSpaces = false;
        line = "";
        width = 0;
      }
    } else {
      if (tokenWidth + width > wordWrapWidth) {
        canPrependSpaces = false;
        linesArray.push(textTokenization.trimRight(line));
        line = "";
        width = 0;
      }
      if (line.length > 0 || !textTokenization.isBreakingSpace(token) || canPrependSpaces) {
        line += token;
        width += tokenWidth;
      }
    }
  }
  const trimmedLine = textTokenization.trimRight(line);
  if (trimmedLine.length > 0) {
    linesArray.push(trimmedLine);
  }
  return linesArray.join("\n");
}

exports.wordWrap = wordWrap;
//# sourceMappingURL=wordWrap.js.map
