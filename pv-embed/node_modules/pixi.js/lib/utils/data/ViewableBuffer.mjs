"use strict";
class ViewableBuffer {
  constructor(sizeOrBuffer) {
    if (typeof sizeOrBuffer === "number") {
      this.rawBinaryData = new ArrayBuffer(sizeOrBuffer);
    } else if (sizeOrBuffer instanceof Uint8Array) {
      this.rawBinaryData = sizeOrBuffer.buffer;
    } else {
      this.rawBinaryData = sizeOrBuffer;
    }
    this.uint32View = new Uint32Array(this.rawBinaryData);
    this.float32View = new Float32Array(this.rawBinaryData);
    this.size = this.rawBinaryData.byteLength;
  }
  /** View on the raw binary data as a `Int8Array`. */
  get int8View() {
    if (!this._int8View) {
      this._int8View = new Int8Array(this.rawBinaryData);
    }
    return this._int8View;
  }
  /** View on the raw binary data as a `Uint8Array`. */
  get uint8View() {
    if (!this._uint8View) {
      this._uint8View = new Uint8Array(this.rawBinaryData);
    }
    return this._uint8View;
  }
  /**  View on the raw binary data as a `Int16Array`. */
  get int16View() {
    if (!this._int16View) {
      this._int16View = new Int16Array(this.rawBinaryData);
    }
    return this._int16View;
  }
  /** View on the raw binary data as a `Int32Array`. */
  get int32View() {
    if (!this._int32View) {
      this._int32View = new Int32Array(this.rawBinaryData);
    }
    return this._int32View;
  }
  /** View on the raw binary data as a `Float64Array`. */
  get float64View() {
    if (!this._float64Array) {
      this._float64Array = new Float64Array(this.rawBinaryData);
    }
    return this._float64Array;
  }
  /** View on the raw binary data as a `BigUint64Array`. */
  get bigUint64View() {
    if (!this._bigUint64Array) {
      this._bigUint64Array = new BigUint64Array(this.rawBinaryData);
    }
    return this._bigUint64Array;
  }
  /**
   * Returns the view of the given type.
   * @param type - One of `int8`, `uint8`, `int16`,
   *    `uint16`, `int32`, `uint32`, and `float32`.
   * @returns - typed array of given type
   */
  view(type) {
    return this[`${type}View`];
  }
  /** Destroys all buffer references. Do not use after calling this. */
  destroy() {
    this.rawBinaryData = null;
    this.uint32View = null;
    this.float32View = null;
    this.uint16View = null;
    this._int8View = null;
    this._uint8View = null;
    this._int16View = null;
    this._int32View = null;
    this._float64Array = null;
    this._bigUint64Array = null;
  }
  /**
   * Returns the size of the given type in bytes.
   * @param type - One of `int8`, `uint8`, `int16`,
   *   `uint16`, `int32`, `uint32`, and `float32`.
   * @returns - size of the type in bytes
   */
  static sizeOf(type) {
    switch (type) {
      case "int8":
      case "uint8":
        return 1;
      case "int16":
      case "uint16":
        return 2;
      case "int32":
      case "uint32":
      case "float32":
        return 4;
      default:
        throw new Error(`${type} isn't a valid view type`);
    }
  }
}

export { ViewableBuffer };
//# sourceMappingURL=ViewableBuffer.mjs.map
