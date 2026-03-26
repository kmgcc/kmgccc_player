'use strict';

var Color = require('../../../../color/Color.js');
var adapter = require('../../../../environment/adapter.js');
var groupD8 = require('../../../../maths/matrix/groupD8.js');
var canUseNewCanvasBlendModes = require('./canUseNewCanvasBlendModes.js');

"use strict";
const canvasUtils = {
  canvas: null,
  convertTintToImage: false,
  cacheStepsPerColorChannel: 8,
  canUseMultiply: canUseNewCanvasBlendModes.canUseNewCanvasBlendModes(),
  tintMethod: null,
  _canvasSourceCache: /* @__PURE__ */ new WeakMap(),
  _unpremultipliedCache: /* @__PURE__ */ new WeakMap(),
  getCanvasSource: (texture) => {
    const source = texture.source;
    const resource = source?.resource;
    if (!resource) {
      return null;
    }
    const isPMA = source.alphaMode === "premultiplied-alpha";
    const resourceWidth = source.resourceWidth ?? source.pixelWidth;
    const resourceHeight = source.resourceHeight ?? source.pixelHeight;
    const needsResize = resourceWidth !== source.pixelWidth || resourceHeight !== source.pixelHeight;
    if (isPMA) {
      if (resource instanceof HTMLCanvasElement || typeof OffscreenCanvas !== "undefined" && resource instanceof OffscreenCanvas) {
        if (!needsResize) {
          return resource;
        }
      }
      const cached = canvasUtils._unpremultipliedCache.get(source);
      if (cached?.resourceId === source._resourceId) {
        return cached.canvas;
      }
    }
    if (resource instanceof Uint8Array || resource instanceof Uint8ClampedArray || resource instanceof Int8Array || resource instanceof Uint16Array || resource instanceof Int16Array || resource instanceof Uint32Array || resource instanceof Int32Array || resource instanceof Float32Array || resource instanceof ArrayBuffer) {
      const cached = canvasUtils._canvasSourceCache.get(source);
      if (cached?.resourceId === source._resourceId) {
        return cached.canvas;
      }
      const canvas = adapter.DOMAdapter.get().createCanvas(source.pixelWidth, source.pixelHeight);
      const context = canvas.getContext("2d");
      const imageData = context.createImageData(source.pixelWidth, source.pixelHeight);
      const data = imageData.data;
      const bytes = resource instanceof ArrayBuffer ? new Uint8Array(resource) : new Uint8Array(resource.buffer, resource.byteOffset, resource.byteLength);
      if (source.format === "bgra8unorm") {
        for (let i = 0; i < data.length && i + 3 < bytes.length; i += 4) {
          data[i] = bytes[i + 2];
          data[i + 1] = bytes[i + 1];
          data[i + 2] = bytes[i];
          data[i + 3] = bytes[i + 3];
        }
      } else {
        data.set(bytes.subarray(0, data.length));
      }
      context.putImageData(imageData, 0, 0);
      canvasUtils._canvasSourceCache.set(source, { canvas, resourceId: source._resourceId });
      return canvas;
    }
    if (isPMA) {
      const canvas = adapter.DOMAdapter.get().createCanvas(source.pixelWidth, source.pixelHeight);
      const context = canvas.getContext("2d", { willReadFrequently: true });
      canvas.width = source.pixelWidth;
      canvas.height = source.pixelHeight;
      context.drawImage(resource, 0, 0);
      const imageData = context.getImageData(0, 0, canvas.width, canvas.height);
      const data = imageData.data;
      for (let i = 0; i < data.length; i += 4) {
        const a = data[i + 3];
        if (a > 0) {
          const alphaInv = 255 / a;
          data[i] = Math.min(255, data[i] * alphaInv + 0.5);
          data[i + 1] = Math.min(255, data[i + 1] * alphaInv + 0.5);
          data[i + 2] = Math.min(255, data[i + 2] * alphaInv + 0.5);
        }
      }
      context.putImageData(imageData, 0, 0);
      canvasUtils._unpremultipliedCache.set(source, { canvas, resourceId: source._resourceId });
      return canvas;
    }
    if (needsResize) {
      const cached = canvasUtils._canvasSourceCache.get(source);
      if (cached?.resourceId === source._resourceId) {
        return cached.canvas;
      }
      const canvas = adapter.DOMAdapter.get().createCanvas(source.pixelWidth, source.pixelHeight);
      const context = canvas.getContext("2d");
      canvas.width = source.pixelWidth;
      canvas.height = source.pixelHeight;
      context.drawImage(resource, 0, 0);
      canvasUtils._canvasSourceCache.set(source, { canvas, resourceId: source._resourceId });
      return canvas;
    }
    return resource;
  },
  getTintedCanvas: (sprite, color) => {
    const texture = sprite.texture;
    const stringColor = Color.Color.shared.setValue(color).toHex();
    const cache = texture.tintCache || (texture.tintCache = {});
    const cachedCanvas = cache[stringColor];
    const resourceId = texture.source._resourceId;
    if (cachedCanvas?.tintId === resourceId) {
      return cachedCanvas;
    }
    const canvas = cachedCanvas && "getContext" in cachedCanvas ? cachedCanvas : adapter.DOMAdapter.get().createCanvas();
    canvasUtils.tintMethod(texture, color, canvas);
    canvas.tintId = resourceId;
    if (canvasUtils.convertTintToImage && canvas.toDataURL !== void 0) {
      const tintImage = adapter.DOMAdapter.get().createImage();
      tintImage.src = canvas.toDataURL();
      tintImage.tintId = resourceId;
      cache[stringColor] = tintImage;
    } else {
      cache[stringColor] = canvas;
    }
    return cache[stringColor];
  },
  getTintedPattern: (texture, color) => {
    const stringColor = Color.Color.shared.setValue(color).toHex();
    const cache = texture.patternCache || (texture.patternCache = {});
    const resourceId = texture.source._resourceId;
    let pattern = cache[stringColor];
    if (pattern?.tintId === resourceId) {
      return pattern;
    }
    if (!canvasUtils.canvas) {
      canvasUtils.canvas = adapter.DOMAdapter.get().createCanvas();
    }
    canvasUtils.tintMethod(texture, color, canvasUtils.canvas);
    const context = canvasUtils.canvas.getContext("2d");
    pattern = context.createPattern(canvasUtils.canvas, "repeat");
    pattern.tintId = resourceId;
    cache[stringColor] = pattern;
    return pattern;
  },
  /**
   * Applies a transform to a CanvasPattern.
   * @param pattern - The pattern to apply the transform to.
   * @param matrix - The matrix to apply.
   * @param matrix.a
   * @param matrix.b
   * @param matrix.c
   * @param matrix.d
   * @param matrix.tx
   * @param matrix.ty
   * @param invert
   */
  applyPatternTransform: (pattern, matrix, invert = true) => {
    if (!matrix) return;
    const patternAny = pattern;
    if (!patternAny.setTransform) return;
    const DOMMatrixCtor = globalThis.DOMMatrix;
    if (!DOMMatrixCtor) return;
    const domMatrix = new DOMMatrixCtor([matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty]);
    patternAny.setTransform(invert ? domMatrix.inverse() : domMatrix);
  },
  tintWithMultiply: (texture, color, canvas) => {
    const context = canvas.getContext("2d");
    const crop = texture.frame.clone();
    const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
    const rotate = texture.rotate;
    crop.x *= resolution;
    crop.y *= resolution;
    crop.width *= resolution;
    crop.height *= resolution;
    const isVertical = groupD8.groupD8.isVertical(rotate);
    const outWidth = isVertical ? crop.height : crop.width;
    const outHeight = isVertical ? crop.width : crop.height;
    canvas.width = Math.ceil(outWidth);
    canvas.height = Math.ceil(outHeight);
    context.save();
    context.fillStyle = Color.Color.shared.setValue(color).toHex();
    context.fillRect(0, 0, outWidth, outHeight);
    context.globalCompositeOperation = "multiply";
    const source = canvasUtils.getCanvasSource(texture);
    if (!source) {
      context.restore();
      return;
    }
    if (rotate) {
      canvasUtils._applyInverseRotation(context, rotate, crop.width, crop.height);
    }
    context.drawImage(
      source,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      0,
      0,
      crop.width,
      crop.height
    );
    context.globalCompositeOperation = "destination-atop";
    context.drawImage(
      source,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      0,
      0,
      crop.width,
      crop.height
    );
    context.restore();
  },
  tintWithOverlay: (texture, color, canvas) => {
    const context = canvas.getContext("2d");
    const crop = texture.frame.clone();
    const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
    const rotate = texture.rotate;
    crop.x *= resolution;
    crop.y *= resolution;
    crop.width *= resolution;
    crop.height *= resolution;
    const isVertical = groupD8.groupD8.isVertical(rotate);
    const outWidth = isVertical ? crop.height : crop.width;
    const outHeight = isVertical ? crop.width : crop.height;
    canvas.width = Math.ceil(outWidth);
    canvas.height = Math.ceil(outHeight);
    context.save();
    context.globalCompositeOperation = "copy";
    context.fillStyle = Color.Color.shared.setValue(color).toHex();
    context.fillRect(0, 0, outWidth, outHeight);
    context.globalCompositeOperation = "destination-atop";
    const source = canvasUtils.getCanvasSource(texture);
    if (!source) {
      context.restore();
      return;
    }
    if (rotate) {
      canvasUtils._applyInverseRotation(context, rotate, crop.width, crop.height);
    }
    context.drawImage(
      source,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      0,
      0,
      crop.width,
      crop.height
    );
    context.restore();
  },
  tintWithPerPixel: (texture, color, canvas) => {
    const context = canvas.getContext("2d");
    const crop = texture.frame.clone();
    const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
    const rotate = texture.rotate;
    crop.x *= resolution;
    crop.y *= resolution;
    crop.width *= resolution;
    crop.height *= resolution;
    const isVertical = groupD8.groupD8.isVertical(rotate);
    const outWidth = isVertical ? crop.height : crop.width;
    const outHeight = isVertical ? crop.width : crop.height;
    canvas.width = Math.ceil(outWidth);
    canvas.height = Math.ceil(outHeight);
    context.save();
    context.globalCompositeOperation = "copy";
    const source = canvasUtils.getCanvasSource(texture);
    if (!source) {
      context.restore();
      return;
    }
    if (rotate) {
      canvasUtils._applyInverseRotation(context, rotate, crop.width, crop.height);
    }
    context.drawImage(
      source,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      0,
      0,
      crop.width,
      crop.height
    );
    context.restore();
    const r = color >> 16 & 255;
    const g = color >> 8 & 255;
    const b = color & 255;
    const imageData = context.getImageData(0, 0, outWidth, outHeight);
    const data = imageData.data;
    for (let i = 0; i < data.length; i += 4) {
      data[i] = data[i] * r / 255;
      data[i + 1] = data[i + 1] * g / 255;
      data[i + 2] = data[i + 2] * b / 255;
    }
    context.putImageData(imageData, 0, 0);
  },
  /**
   * Applies inverse rotation transform to context for texture packer rotation compensation.
   * Supports all 16 groupD8 symmetries (rotations and reflections).
   * @param context - Canvas 2D context
   * @param rotate - The groupD8 rotation value
   * @param srcWidth - Source crop width (before rotation)
   * @param srcHeight - Source crop height (before rotation)
   */
  _applyInverseRotation: (context, rotate, srcWidth, srcHeight) => {
    const inv = groupD8.groupD8.inv(rotate);
    const a = groupD8.groupD8.uX(inv);
    const b = groupD8.groupD8.uY(inv);
    const c = groupD8.groupD8.vX(inv);
    const d = groupD8.groupD8.vY(inv);
    const tx = -Math.min(0, a * srcWidth, c * srcHeight, a * srcWidth + c * srcHeight);
    const ty = -Math.min(0, b * srcWidth, d * srcHeight, b * srcWidth + d * srcHeight);
    context.transform(a, b, c, d, tx, ty);
  }
};
canvasUtils.tintMethod = canvasUtils.canUseMultiply ? canvasUtils.tintWithMultiply : canvasUtils.tintWithPerPixel;

exports.canvasUtils = canvasUtils;
//# sourceMappingURL=canvasUtils.js.map
