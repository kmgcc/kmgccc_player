import { DOMAdapter } from '../../environment/adapter.mjs';
import { nextPow2 } from '../../maths/misc/pow2.mjs';
import { Rectangle } from '../../maths/shapes/Rectangle.mjs';

"use strict";
let _internalCanvas = null;
let _internalContext = null;
function ensureInternalCanvas(width, height) {
  if (!_internalCanvas) {
    _internalCanvas = DOMAdapter.get().createCanvas(256, 128);
    _internalContext = _internalCanvas.getContext("2d", { willReadFrequently: true });
    _internalContext.globalCompositeOperation = "copy";
    _internalContext.globalAlpha = 1;
  }
  if (_internalCanvas.width < width || _internalCanvas.height < height) {
    _internalCanvas.width = nextPow2(width);
    _internalCanvas.height = nextPow2(height);
  }
}
function checkRow(data, width, y) {
  for (let x = 0, index = 4 * y * width; x < width; ++x, index += 4) {
    if (data[index + 3] !== 0) return false;
  }
  return true;
}
function checkColumn(data, width, x, top, bottom) {
  const stride = 4 * width;
  for (let y = top, index = top * stride + 4 * x; y <= bottom; ++y, index += stride) {
    if (data[index + 3] !== 0) return false;
  }
  return true;
}
function getCanvasBoundingBox(...args) {
  let options = args[0];
  if (!options.canvas) {
    options = { canvas: args[0], resolution: args[1] };
  }
  const { canvas } = options;
  const resolution = Math.min(options.resolution ?? 1, 1);
  const width = options.width ?? canvas.width;
  const height = options.height ?? canvas.height;
  let output = options.output;
  ensureInternalCanvas(width, height);
  if (!_internalContext) {
    throw new TypeError("Failed to get canvas 2D context");
  }
  _internalContext.drawImage(
    canvas,
    0,
    0,
    width,
    height,
    0,
    0,
    width * resolution,
    height * resolution
  );
  const imageData = _internalContext.getImageData(0, 0, width, height);
  const data = imageData.data;
  let left = 0;
  let top = 0;
  let right = width - 1;
  let bottom = height - 1;
  while (top < height && checkRow(data, width, top)) ++top;
  if (top === height) return Rectangle.EMPTY;
  while (checkRow(data, width, bottom)) --bottom;
  while (checkColumn(data, width, left, top, bottom)) ++left;
  while (checkColumn(data, width, right, top, bottom)) --right;
  ++right;
  ++bottom;
  _internalContext.globalCompositeOperation = "source-over";
  _internalContext.strokeRect(left, top, right - left, bottom - top);
  _internalContext.globalCompositeOperation = "copy";
  output ?? (output = new Rectangle());
  output.set(left / resolution, top / resolution, (right - left) / resolution, (bottom - top) / resolution);
  return output;
}

export { getCanvasBoundingBox };
//# sourceMappingURL=getCanvasBoundingBox.mjs.map
