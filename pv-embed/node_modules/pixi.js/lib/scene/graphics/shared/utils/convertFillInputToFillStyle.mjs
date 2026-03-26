import { Color } from '../../../../color/Color.mjs';
import { Texture } from '../../../../rendering/renderers/shared/texture/Texture.mjs';
import { FillGradient } from '../fill/FillGradient.mjs';
import { FillPattern } from '../fill/FillPattern.mjs';

"use strict";
function isColorLike(value) {
  return Color.isColorLike(value);
}
function isFillPattern(value) {
  return value instanceof FillPattern;
}
function isFillGradient(value) {
  return value instanceof FillGradient;
}
function isTexture(value) {
  return value instanceof Texture;
}
function handleColorLike(fill, value, defaultStyle) {
  const temp = Color.shared.setValue(value ?? 0);
  fill.color = temp.toNumber();
  fill.alpha = temp.alpha === 1 ? defaultStyle.alpha : temp.alpha;
  fill.texture = Texture.WHITE;
  return { ...defaultStyle, ...fill };
}
function handleTexture(fill, value, defaultStyle) {
  fill.texture = value;
  return { ...defaultStyle, ...fill };
}
function handleFillPattern(fill, value, defaultStyle) {
  fill.fill = value;
  fill.color = 16777215;
  fill.texture = value.texture;
  fill.matrix = value.transform;
  return { ...defaultStyle, ...fill };
}
function handleFillGradient(fill, value, defaultStyle) {
  value.buildGradient();
  fill.fill = value;
  fill.color = 16777215;
  fill.texture = value.texture;
  fill.matrix = value.transform;
  fill.textureSpace = value.textureSpace;
  return { ...defaultStyle, ...fill };
}
function handleFillObject(value, defaultStyle) {
  const style = { ...defaultStyle, ...value };
  const color = Color.shared.setValue(style.color);
  style.alpha *= color.alpha;
  style.color = color.toNumber();
  return style;
}
function toFillStyle(value, defaultStyle) {
  if (value === void 0 || value === null) {
    return null;
  }
  const fill = {};
  const objectStyle = value;
  if (isColorLike(value)) {
    return handleColorLike(fill, value, defaultStyle);
  } else if (isTexture(value)) {
    return handleTexture(fill, value, defaultStyle);
  } else if (isFillPattern(value)) {
    return handleFillPattern(fill, value, defaultStyle);
  } else if (isFillGradient(value)) {
    return handleFillGradient(fill, value, defaultStyle);
  } else if (objectStyle.fill && isFillPattern(objectStyle.fill)) {
    return handleFillPattern(objectStyle, objectStyle.fill, defaultStyle);
  } else if (objectStyle.fill && isFillGradient(objectStyle.fill)) {
    return handleFillGradient(objectStyle, objectStyle.fill, defaultStyle);
  }
  return handleFillObject(objectStyle, defaultStyle);
}
function toStrokeStyle(value, defaultStyle) {
  const { width, alignment, miterLimit, cap, join, pixelLine, ...rest } = defaultStyle;
  const fill = toFillStyle(value, rest);
  if (!fill) {
    return null;
  }
  return {
    width,
    alignment,
    miterLimit,
    cap,
    join,
    pixelLine,
    ...fill
  };
}

export { toFillStyle, toStrokeStyle };
//# sourceMappingURL=convertFillInputToFillStyle.mjs.map
