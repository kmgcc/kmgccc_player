'use strict';

var Container = require('../../container/Container.js');
var CanvasTextMetrics = require('../../text/canvas/CanvasTextMetrics.js');
var BitmapFontManager = require('../BitmapFontManager.js');
var BitmapText = require('../BitmapText.js');
var getBitmapTextLayout = require('./getBitmapTextLayout.js');

"use strict";
function bitmapTextSplit(options) {
  const { text, style, chars: existingChars } = options;
  const textStyle = style;
  const font = BitmapFontManager.BitmapFontManager.getFont(text, textStyle);
  const segments = CanvasTextMetrics.CanvasTextMetrics.graphemeSegmenter(text);
  const layout = getBitmapTextLayout.getBitmapTextLayout(segments, textStyle, font, true);
  const scale = layout.scale;
  const chars = [];
  const words = [];
  const lines = [];
  const lineHeight = style.lineHeight ? style.lineHeight : font.lineHeight * scale;
  let yOffset = 0;
  for (const line of layout.lines) {
    if (line.chars.length === 0) continue;
    const lineContainer = new Container.Container({ label: "line" });
    lineContainer.y = yOffset;
    lines.push(lineContainer);
    let currentWordContainer = new Container.Container({ label: "word" });
    let currentWordStartIndex = 0;
    for (let i = 0; i < line.chars.length; i++) {
      const char = line.chars[i];
      if (!char) continue;
      const charData = font.chars[char];
      if (!charData) continue;
      const isSpace = char === " ";
      const isLastChar = i === line.chars.length - 1;
      let charInstance;
      if (existingChars.length > 0) {
        charInstance = existingChars.shift();
        charInstance.text = char;
        charInstance.style = textStyle;
        charInstance.label = `char-${char}`;
        charInstance.x = line.charPositions[i] * scale - line.charPositions[currentWordStartIndex] * scale;
      } else {
        charInstance = new BitmapText.BitmapText({
          text: char,
          style: textStyle,
          label: `char-${char}`,
          x: line.charPositions[i] * scale - line.charPositions[currentWordStartIndex] * scale
        });
      }
      if (!isSpace) {
        chars.push(charInstance);
        currentWordContainer.addChild(charInstance);
      }
      if (isSpace || isLastChar) {
        if (currentWordContainer.children.length > 0) {
          currentWordContainer.x = line.charPositions[currentWordStartIndex] * scale;
          words.push(currentWordContainer);
          lineContainer.addChild(currentWordContainer);
          currentWordContainer = new Container.Container({ label: "word" });
          currentWordStartIndex = i + 1;
        }
      }
    }
    yOffset += lineHeight;
  }
  return { chars, lines, words };
}

exports.bitmapTextSplit = bitmapTextSplit;
//# sourceMappingURL=bitmapTextSplit.js.map
