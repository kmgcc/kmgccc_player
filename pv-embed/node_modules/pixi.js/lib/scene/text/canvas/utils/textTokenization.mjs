"use strict";
const NEWLINES = [
  10,
  // line feed
  13
  // carriage return
];
const NEWLINES_SET = new Set(NEWLINES);
const BREAKING_SPACES = [
  9,
  // character tabulation
  32,
  // space
  8192,
  // en quad
  8193,
  // em quad
  8194,
  // en space
  8195,
  // em space
  8196,
  // three-per-em space
  8197,
  // four-per-em space
  8198,
  // six-per-em space
  8200,
  // punctuation space
  8201,
  // thin space
  8202,
  // hair space
  8287,
  // medium mathematical space
  12288
  // ideographic space
];
const BREAKING_SPACES_SET = new Set(BREAKING_SPACES);
const COLLAPSIBLE_SPACES = [
  9,
  // character tabulation (tab)
  32
  // space
];
const COLLAPSIBLE_SPACES_SET = new Set(COLLAPSIBLE_SPACES);
const BREAK_AFTER_CHARS = [
  45,
  // hyphen-minus
  8208,
  // unicode hyphen
  8211,
  // en-dash
  8212,
  // em-dash
  173
  // soft hyphen
];
const BREAK_AFTER_CHARS_SET = new Set(BREAK_AFTER_CHARS);
const NEWLINE_SPLIT_REGEX = /(\r\n|\r|\n)/;
const NEWLINE_MATCH_REGEX = /(?:\r\n|\r|\n)/;
function isNewline(char) {
  if (typeof char !== "string") {
    return false;
  }
  return NEWLINES_SET.has(char.charCodeAt(0));
}
function isBreakingSpace(char, _nextChar) {
  if (typeof char !== "string") {
    return false;
  }
  return BREAKING_SPACES_SET.has(char.charCodeAt(0));
}
function isCollapsibleSpace(char) {
  if (typeof char !== "string") {
    return false;
  }
  return COLLAPSIBLE_SPACES_SET.has(char.charCodeAt(0));
}
function isBreakAfterChar(char) {
  if (typeof char !== "string") {
    return false;
  }
  return BREAK_AFTER_CHARS_SET.has(char.charCodeAt(0));
}
function collapseSpaces(whiteSpace) {
  return whiteSpace === "normal" || whiteSpace === "pre-line";
}
function collapseNewlines(whiteSpace) {
  return whiteSpace === "normal";
}
function trimRight(text) {
  if (typeof text !== "string") {
    return "";
  }
  let i = text.length - 1;
  while (i >= 0 && isBreakingSpace(text[i])) {
    i--;
  }
  return i < text.length - 1 ? text.slice(0, i + 1) : text;
}
function tokenize(text) {
  const tokens = [];
  const tokenChars = [];
  if (typeof text !== "string") {
    return tokens;
  }
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    const nextChar = text[i + 1];
    if (isBreakingSpace(char, nextChar) || isNewline(char)) {
      if (tokenChars.length > 0) {
        tokens.push(tokenChars.join(""));
        tokenChars.length = 0;
      }
      if (char === "\r" && nextChar === "\n") {
        tokens.push("\r\n");
        i++;
      } else {
        tokens.push(char);
      }
      continue;
    }
    tokenChars.push(char);
    if (isBreakAfterChar(char) && nextChar && !isBreakingSpace(nextChar) && !isNewline(nextChar)) {
      tokens.push(tokenChars.join(""));
      tokenChars.length = 0;
    }
  }
  if (tokenChars.length > 0) {
    tokens.push(tokenChars.join(""));
  }
  return tokens;
}
function getCharacterGroups(token, breakWords, splitFn, canBreakCharsFn) {
  const characters = splitFn(token);
  const groups = [];
  for (let j = 0; j < characters.length; j++) {
    let char = characters[j];
    let lastChar = char;
    let k = 1;
    while (characters[j + k]) {
      const nextChar = characters[j + k];
      if (!canBreakCharsFn(lastChar, nextChar, token, j, breakWords)) {
        char += nextChar;
        lastChar = nextChar;
        k++;
      } else {
        break;
      }
    }
    j += k - 1;
    groups.push(char);
  }
  return groups;
}

export { BREAKING_SPACES, BREAKING_SPACES_SET, BREAK_AFTER_CHARS, BREAK_AFTER_CHARS_SET, COLLAPSIBLE_SPACES, COLLAPSIBLE_SPACES_SET, NEWLINES, NEWLINES_SET, NEWLINE_MATCH_REGEX, NEWLINE_SPLIT_REGEX, collapseNewlines, collapseSpaces, getCharacterGroups, isBreakAfterChar, isBreakingSpace, isCollapsibleSpace, isNewline, tokenize, trimRight };
//# sourceMappingURL=textTokenization.mjs.map
