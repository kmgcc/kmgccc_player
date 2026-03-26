import { Container } from '../../container/Container.mjs';
import { CanvasTextMetrics } from '../../text/canvas/CanvasTextMetrics.mjs';
import { BitmapFontManager } from '../BitmapFontManager.mjs';
import { BitmapText } from '../BitmapText.mjs';
import { getBitmapTextLayout } from './getBitmapTextLayout.mjs';

"use strict";
function bitmapTextSplit(options) {
  const { text, style, chars: existingChars } = options;
  const textStyle = style;
  const font = BitmapFontManager.getFont(text, textStyle);
  const segments = CanvasTextMetrics.graphemeSegmenter(text);
  const layout = getBitmapTextLayout(segments, textStyle, font, true);
  const scale = layout.scale;
  const chars = [];
  const words = [];
  const lines = [];
  const lineHeight = style.lineHeight ? style.lineHeight : font.lineHeight * scale;
  let yOffset = 0;
  for (const line of layout.lines) {
    if (line.chars.length === 0) continue;
    const lineContainer = new Container({ label: "line" });
    lineContainer.y = yOffset;
    lines.push(lineContainer);
    let currentWordContainer = new Container({ label: "word" });
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
        charInstance = new BitmapText({
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
          currentWordContainer = new Container({ label: "word" });
          currentWordStartIndex = i + 1;
        }
      }
    }
    yOffset += lineHeight;
  }
  return { chars, lines, words };
}

export { bitmapTextSplit };
//# sourceMappingURL=bitmapTextSplit.mjs.map
