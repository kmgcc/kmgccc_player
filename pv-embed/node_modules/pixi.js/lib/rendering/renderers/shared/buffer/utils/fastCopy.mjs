"use strict";
function fastCopy(sourceBuffer, destinationBuffer, sourceOffset, byteLength) {
  sourceOffset ?? (sourceOffset = 0);
  byteLength ?? (byteLength = Math.min(sourceBuffer.byteLength - sourceOffset, destinationBuffer.byteLength));
  if (!(sourceOffset & 7) && !(byteLength & 7)) {
    const len = byteLength / 8;
    new Float64Array(destinationBuffer, 0, len).set(new Float64Array(sourceBuffer, sourceOffset, len));
  } else if (!(sourceOffset & 3) && !(byteLength & 3)) {
    const len = byteLength / 4;
    new Float32Array(destinationBuffer, 0, len).set(new Float32Array(sourceBuffer, sourceOffset, len));
  } else {
    new Uint8Array(destinationBuffer).set(new Uint8Array(sourceBuffer, sourceOffset, byteLength));
  }
}

export { fastCopy };
//# sourceMappingURL=fastCopy.mjs.map
