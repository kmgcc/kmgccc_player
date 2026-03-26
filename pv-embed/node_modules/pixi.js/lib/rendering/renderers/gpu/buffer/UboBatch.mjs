"use strict";
class UboBatch {
  constructor({ minUniformOffsetAlignment }) {
    this._minUniformOffsetAlignment = 256;
    this.byteIndex = 0;
    this._minUniformOffsetAlignment = minUniformOffsetAlignment;
    this.data = new Float32Array(65535);
  }
  clear() {
    this.byteIndex = 0;
  }
  addEmptyGroup(size) {
    if (size > this._minUniformOffsetAlignment / 4) {
      throw new Error(`UniformBufferBatch: array is too large: ${size * 4}`);
    }
    const start = this.byteIndex;
    let newSize = start + size * 4;
    newSize = Math.ceil(newSize / this._minUniformOffsetAlignment) * this._minUniformOffsetAlignment;
    if (newSize > this.data.length * 4) {
      throw new Error("UniformBufferBatch: ubo batch got too big");
    }
    this.byteIndex = newSize;
    return start;
  }
  addGroup(array) {
    const offset = this.addEmptyGroup(array.length);
    for (let i = 0; i < array.length; i++) {
      this.data[offset / 4 + i] = array[i];
    }
    return offset;
  }
  destroy() {
    this.data = null;
  }
}

export { UboBatch };
//# sourceMappingURL=UboBatch.mjs.map
