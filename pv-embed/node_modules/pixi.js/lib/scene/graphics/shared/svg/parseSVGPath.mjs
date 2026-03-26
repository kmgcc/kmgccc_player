import parse from 'parse-svg-path';
import { warn } from '../../../../utils/logging/warn.mjs';

"use strict";
function parseSVGPath(svgPath, path) {
  const commands = parse(svgPath);
  const subpaths = [];
  let currentSubPath = null;
  let lastX = 0;
  let lastY = 0;
  for (let i = 0; i < commands.length; i++) {
    const command = commands[i];
    const type = command[0];
    const data = command;
    switch (type) {
      case "M":
        lastX = data[1];
        lastY = data[2];
        path.moveTo(lastX, lastY);
        break;
      case "m":
        lastX += data[1];
        lastY += data[2];
        path.moveTo(lastX, lastY);
        break;
      case "H":
        lastX = data[1];
        path.lineTo(lastX, lastY);
        break;
      case "h":
        lastX += data[1];
        path.lineTo(lastX, lastY);
        break;
      case "V":
        lastY = data[1];
        path.lineTo(lastX, lastY);
        break;
      case "v":
        lastY += data[1];
        path.lineTo(lastX, lastY);
        break;
      case "L":
        lastX = data[1];
        lastY = data[2];
        path.lineTo(lastX, lastY);
        break;
      case "l":
        lastX += data[1];
        lastY += data[2];
        path.lineTo(lastX, lastY);
        break;
      case "C":
        lastX = data[5];
        lastY = data[6];
        path.bezierCurveTo(
          data[1],
          data[2],
          // First control point
          data[3],
          data[4],
          // Second control point
          lastX,
          lastY
          // End point
        );
        break;
      case "c":
        path.bezierCurveTo(
          lastX + data[1],
          lastY + data[2],
          // First control point
          lastX + data[3],
          lastY + data[4],
          // Second control point
          lastX + data[5],
          lastY + data[6]
          // End point
        );
        lastX += data[5];
        lastY += data[6];
        break;
      case "S":
        lastX = data[3];
        lastY = data[4];
        path.bezierCurveToShort(
          data[1],
          data[2],
          // Control point
          lastX,
          lastY
          // End point
        );
        break;
      case "s":
        path.bezierCurveToShort(
          lastX + data[1],
          lastY + data[2],
          // Control point
          lastX + data[3],
          lastY + data[4]
          // End point
        );
        lastX += data[3];
        lastY += data[4];
        break;
      case "Q":
        lastX = data[3];
        lastY = data[4];
        path.quadraticCurveTo(
          data[1],
          data[2],
          // Control point
          lastX,
          lastY
          // End point
        );
        break;
      case "q":
        path.quadraticCurveTo(
          lastX + data[1],
          lastY + data[2],
          // Control point
          lastX + data[3],
          lastY + data[4]
          // End point
        );
        lastX += data[3];
        lastY += data[4];
        break;
      case "T":
        lastX = data[1];
        lastY = data[2];
        path.quadraticCurveToShort(
          lastX,
          lastY
          // End point
        );
        break;
      case "t":
        lastX += data[1];
        lastY += data[2];
        path.quadraticCurveToShort(
          lastX,
          lastY
          // End point
        );
        break;
      case "A":
        lastX = data[6];
        lastY = data[7];
        path.arcToSvg(
          data[1],
          // rx
          data[2],
          // ry
          data[3],
          // x-axis-rotation
          data[4],
          // large-arc-flag
          data[5],
          // sweep-flag
          lastX,
          lastY
          // End point
        );
        break;
      case "a":
        lastX += data[6];
        lastY += data[7];
        path.arcToSvg(
          data[1],
          // rx
          data[2],
          // ry
          data[3],
          // x-axis-rotation
          data[4],
          // large-arc-flag
          data[5],
          // sweep-flag
          lastX,
          lastY
          // End point
        );
        break;
      case "Z":
      // Close Path
      case "z":
        path.closePath();
        if (subpaths.length > 0) {
          currentSubPath = subpaths.pop();
          if (currentSubPath) {
            lastX = currentSubPath.startX;
            lastY = currentSubPath.startY;
          } else {
            lastX = 0;
            lastY = 0;
          }
        }
        currentSubPath = null;
        break;
      default:
        warn(`Unknown SVG path command: ${type}`);
    }
    if (type !== "Z" && type !== "z") {
      if (currentSubPath === null) {
        currentSubPath = { startX: lastX, startY: lastY };
        subpaths.push(currentSubPath);
      }
    }
  }
  return path;
}

export { parseSVGPath };
//# sourceMappingURL=parseSVGPath.mjs.map
