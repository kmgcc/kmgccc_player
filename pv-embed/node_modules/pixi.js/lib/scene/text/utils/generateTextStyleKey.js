'use strict';

var Color = require('../../../color/Color.js');

"use strict";
const valuesToIterateForKeys = [
  "align",
  "breakWords",
  "cssOverrides",
  "fontVariant",
  "fontWeight",
  "leading",
  "letterSpacing",
  "lineHeight",
  "padding",
  "textBaseline",
  "trim",
  "whiteSpace",
  "wordWrap",
  "wordWrapWidth",
  "fontFamily",
  "fontStyle",
  "fontSize"
];
function generateTextStyleKey(style) {
  const key = [];
  let index = 0;
  for (let i = 0; i < valuesToIterateForKeys.length; i++) {
    const prop = `_${valuesToIterateForKeys[i]}`;
    key[index++] = style[prop];
  }
  index = addFillStyleKey(style._fill, key, index);
  index = addStokeStyleKey(style._stroke, key, index);
  index = addDropShadowKey(style.dropShadow, key, index);
  index = addFiltersKey(style.filters, key, index);
  return key.join("-");
}
function addFiltersKey(filters, key, index) {
  if (!filters) return index;
  for (const filter of filters) {
    key[index++] = filter.uid;
  }
  return index;
}
function addFillStyleKey(fillStyle, key, index) {
  if (!fillStyle) return index;
  key[index++] = fillStyle.color;
  key[index++] = fillStyle.alpha;
  key[index++] = fillStyle.fill?.styleKey;
  return index;
}
function addStokeStyleKey(strokeStyle, key, index) {
  if (!strokeStyle) return index;
  index = addFillStyleKey(strokeStyle, key, index);
  key[index++] = strokeStyle.width;
  key[index++] = strokeStyle.alignment;
  key[index++] = strokeStyle.cap;
  key[index++] = strokeStyle.join;
  key[index++] = strokeStyle.miterLimit;
  return index;
}
function addDropShadowKey(dropShadow, key, index) {
  if (!dropShadow) return index;
  key[index++] = dropShadow.alpha;
  key[index++] = dropShadow.angle;
  key[index++] = dropShadow.blur;
  key[index++] = dropShadow.distance;
  key[index++] = Color.Color.shared.setValue(dropShadow.color).toNumber();
  return index;
}

exports.generateTextStyleKey = generateTextStyleKey;
//# sourceMappingURL=generateTextStyleKey.js.map
