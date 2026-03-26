'use strict';

"use strict";
function hasTagStyles(style) {
  return !!style.tagStyles && Object.keys(style.tagStyles).length > 0;
}
function hasTagMarkup(text) {
  return text.includes("<");
}
function createMergedStyle(baseStyle, overrides) {
  return baseStyle.clone().assign(overrides);
}
function parseTaggedText(text, style) {
  const runs = [];
  const tagStyles = style.tagStyles;
  if (!hasTagStyles(style) || !hasTagMarkup(text)) {
    runs.push({ text, style });
    return runs;
  }
  const styleStack = [style];
  const tagStack = [];
  let currentText = "";
  let i = 0;
  while (i < text.length) {
    const char = text[i];
    if (char === "<") {
      const closeIndex = text.indexOf(">", i);
      if (closeIndex === -1) {
        currentText += char;
        i++;
        continue;
      }
      const tagContent = text.slice(i + 1, closeIndex);
      if (tagContent.startsWith("/")) {
        const closingTagName = tagContent.slice(1).trim();
        if (tagStack.length > 0 && tagStack[tagStack.length - 1] === closingTagName) {
          if (currentText.length > 0) {
            runs.push({
              text: currentText,
              style: styleStack[styleStack.length - 1]
            });
            currentText = "";
          }
          styleStack.pop();
          tagStack.pop();
          i = closeIndex + 1;
          continue;
        } else {
          currentText += text.slice(i, closeIndex + 1);
          i = closeIndex + 1;
          continue;
        }
      } else {
        const tagName = tagContent.trim();
        if (tagStyles[tagName]) {
          if (currentText.length > 0) {
            runs.push({
              text: currentText,
              style: styleStack[styleStack.length - 1]
            });
            currentText = "";
          }
          const currentStyle = styleStack[styleStack.length - 1];
          const mergedStyle = createMergedStyle(currentStyle, tagStyles[tagName]);
          styleStack.push(mergedStyle);
          tagStack.push(tagName);
          i = closeIndex + 1;
          continue;
        } else {
          currentText += text.slice(i, closeIndex + 1);
          i = closeIndex + 1;
          continue;
        }
      }
    } else {
      currentText += char;
      i++;
    }
  }
  if (currentText.length > 0) {
    runs.push({
      text: currentText,
      style: styleStack[styleStack.length - 1]
    });
  }
  return runs;
}
function getPlainText(text, style) {
  if (!hasTagStyles(style) || !hasTagMarkup(text)) {
    return text;
  }
  const runs = parseTaggedText(text, style);
  return runs.map((run) => run.text).join("");
}

exports.getPlainText = getPlainText;
exports.hasTagMarkup = hasTagMarkup;
exports.hasTagStyles = hasTagStyles;
exports.parseTaggedText = parseTaggedText;
//# sourceMappingURL=parseTaggedText.js.map
