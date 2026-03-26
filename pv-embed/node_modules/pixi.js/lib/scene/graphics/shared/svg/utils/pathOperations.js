'use strict';

var GraphicsPath = require('../../path/GraphicsPath.js');

"use strict";
function extractSubpaths(pathData) {
  const parts = pathData.split(/(?=[Mm])/);
  const subpaths = parts.filter((part) => part.trim().length > 0);
  return subpaths;
}
function calculatePathArea(pathData) {
  const coords = pathData.match(/[-+]?[0-9]*\.?[0-9]+/g);
  if (!coords || coords.length < 4) return 0;
  const numbers = coords.map(Number);
  const xs = [];
  const ys = [];
  for (let i = 0; i < numbers.length; i += 2) {
    if (i + 1 < numbers.length) {
      xs.push(numbers[i]);
      ys.push(numbers[i + 1]);
    }
  }
  if (xs.length === 0 || ys.length === 0) return 0;
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const area = (maxX - minX) * (maxY - minY);
  return area;
}
function appendSVGPath(pathData, graphicsPath) {
  const tempPath = new GraphicsPath.GraphicsPath(pathData, false);
  for (const instruction of tempPath.instructions) {
    graphicsPath.instructions.push(instruction);
  }
}

exports.appendSVGPath = appendSVGPath;
exports.calculatePathArea = calculatePathArea;
exports.extractSubpaths = extractSubpaths;
//# sourceMappingURL=pathOperations.js.map
