"use strict";
function applyProjectiveTransformationToPlane(width, height, geometry, transformationMatrix) {
  const buffer = geometry.buffers[0];
  const vertices = buffer.data;
  const { verticesX, verticesY } = geometry;
  const sizeX = width / (verticesX - 1);
  const sizeY = height / (verticesY - 1);
  let index = 0;
  const a00 = transformationMatrix[0];
  const a01 = transformationMatrix[1];
  const a02 = transformationMatrix[2];
  const a10 = transformationMatrix[3];
  const a11 = transformationMatrix[4];
  const a12 = transformationMatrix[5];
  const a20 = transformationMatrix[6];
  const a21 = transformationMatrix[7];
  const a22 = transformationMatrix[8];
  for (let i = 0; i < vertices.length; i += 2) {
    const x = index % verticesX * sizeX;
    const y = (index / verticesX | 0) * sizeY;
    const newX = a00 * x + a01 * y + a02;
    const newY = a10 * x + a11 * y + a12;
    const w = a20 * x + a21 * y + a22;
    vertices[i] = newX / w;
    vertices[i + 1] = newY / w;
    index++;
  }
  buffer.update();
}

export { applyProjectiveTransformationToPlane };
//# sourceMappingURL=applyProjectiveTransformationToPlane.mjs.map
