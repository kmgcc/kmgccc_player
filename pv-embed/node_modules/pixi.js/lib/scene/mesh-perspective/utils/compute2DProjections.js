'use strict';

"use strict";
function computeAdjugate(out, matrix) {
  const a00 = matrix[0];
  const a01 = matrix[1];
  const a02 = matrix[2];
  const a10 = matrix[3];
  const a11 = matrix[4];
  const a12 = matrix[5];
  const a20 = matrix[6];
  const a21 = matrix[7];
  const a22 = matrix[8];
  out[0] = a11 * a22 - a12 * a21;
  out[1] = a02 * a21 - a01 * a22;
  out[2] = a01 * a12 - a02 * a11;
  out[3] = a12 * a20 - a10 * a22;
  out[4] = a00 * a22 - a02 * a20;
  out[5] = a02 * a10 - a00 * a12;
  out[6] = a10 * a21 - a11 * a20;
  out[7] = a01 * a20 - a00 * a21;
  out[8] = a00 * a11 - a01 * a10;
  return out;
}
function multiplyMatrix3x3(out, a, b) {
  const a00 = a[0];
  const a01 = a[1];
  const a02 = a[2];
  const a10 = a[3];
  const a11 = a[4];
  const a12 = a[5];
  const a20 = a[6];
  const a21 = a[7];
  const a22 = a[8];
  const b00 = b[0];
  const b01 = b[1];
  const b02 = b[2];
  const b10 = b[3];
  const b11 = b[4];
  const b12 = b[5];
  const b20 = b[6];
  const b21 = b[7];
  const b22 = b[8];
  out[0] = b00 * a00 + b01 * a10 + b02 * a20;
  out[1] = b00 * a01 + b01 * a11 + b02 * a21;
  out[2] = b00 * a02 + b01 * a12 + b02 * a22;
  out[3] = b10 * a00 + b11 * a10 + b12 * a20;
  out[4] = b10 * a01 + b11 * a11 + b12 * a21;
  out[5] = b10 * a02 + b11 * a12 + b12 * a22;
  out[6] = b20 * a00 + b21 * a10 + b22 * a20;
  out[7] = b20 * a01 + b21 * a11 + b22 * a21;
  out[8] = b20 * a02 + b21 * a12 + b22 * a22;
  return out;
}
function multiplyMatrixAndVector(out, m, v) {
  const x = v[0];
  const y = v[1];
  const z = v[2];
  out[0] = m[0] * x + m[1] * y + m[2] * z;
  out[1] = m[3] * x + m[4] * y + m[5] * z;
  out[2] = m[6] * x + m[7] * y + m[8] * z;
  return out;
}
const tempMatrix = [0, 0, 0, 0, 0, 0, 0, 0, 0];
const tempVec = [0, 0, 0];
const tempVec2 = [0, 0, 0];
function generateBasisToPointsMatrix(out, x1, y1, x2, y2, x3, y3, x4, y4) {
  const m = tempMatrix;
  m[0] = x1;
  m[1] = x2;
  m[2] = x3;
  m[3] = y1;
  m[4] = y2;
  m[5] = y3;
  m[6] = 1;
  m[7] = 1;
  m[8] = 1;
  const adjugateM = computeAdjugate(
    out,
    // reusing out as adjugateM is only used once
    m
  );
  tempVec2[0] = x4;
  tempVec2[1] = y4;
  tempVec2[2] = 1;
  const v = multiplyMatrixAndVector(
    tempVec,
    adjugateM,
    tempVec2
  );
  const diagonalMatrix = out;
  out[0] = v[0];
  out[1] = 0;
  out[2] = 0;
  out[3] = 0;
  out[4] = v[1];
  out[5] = 0;
  out[6] = 0;
  out[7] = 0;
  out[8] = v[2];
  return multiplyMatrix3x3(out, diagonalMatrix, m);
}
const tempSourceMatrix = [0, 0, 0, 0, 0, 0, 0, 0, 0];
const tempDestinationMatrix = [0, 0, 0, 0, 0, 0, 0, 0, 0];
function compute2DProjection(out, x1s, y1s, x1d, y1d, x2s, y2s, x2d, y2d, x3s, y3s, x3d, y3d, x4s, y4s, x4d, y4d) {
  const sourceMatrix = generateBasisToPointsMatrix(
    tempSourceMatrix,
    x1s,
    y1s,
    x2s,
    y2s,
    x3s,
    y3s,
    x4s,
    y4s
  );
  const destinationMatrix = generateBasisToPointsMatrix(
    tempDestinationMatrix,
    x1d,
    y1d,
    x2d,
    y2d,
    x3d,
    y3d,
    x4d,
    y4d
  );
  return multiplyMatrix3x3(
    out,
    computeAdjugate(sourceMatrix, sourceMatrix),
    destinationMatrix
  );
}

exports.compute2DProjection = compute2DProjection;
//# sourceMappingURL=compute2DProjections.js.map
