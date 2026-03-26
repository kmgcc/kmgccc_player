import EventEmitter from 'eventemitter3';
import { uid } from '../../../../utils/data/uid.mjs';
import { BufferUsage } from './const.mjs';

"use strict";
class Buffer extends EventEmitter {
  /**
   * Creates a new Buffer with the given options
   * @param options - the options for the buffer
   */
  constructor(options) {
    let { data, size } = options;
    const { usage, label, shrinkToFit } = options;
    super();
    /**
     * emits when the underlying buffer has changed shape (i.e. resized)
     * letting the renderer know that it needs to discard the old buffer on the GPU and create a new one
     * @event change
     */
    /**
     * emits when the underlying buffer data has been updated. letting the renderer know
     * that it needs to update the buffer on the GPU
     * @event update
     */
    /**
     * emits when the buffer is destroyed. letting the renderer know that it needs to destroy the buffer on the GPU
     * @event destroy
     */
    /** @internal */
    this._gpuData = /* @__PURE__ */ Object.create(null);
    /** @internal */
    this._gcLastUsed = -1;
    /** If set to true, the buffer will be garbage collected automatically when it is not used. */
    this.autoGarbageCollect = true;
    /** a unique id for this uniform group used through the renderer */
    this.uid = uid("buffer");
    /**
     * a resource type, used to identify how to handle it when its in a bind group / shader resource
     * @internal
     */
    this._resourceType = "buffer";
    /**
     * the resource id used internally by the renderer to build bind group keys
     * @internal
     */
    this._resourceId = uid("resource");
    /**
     * used internally to know if a uniform group was used in the last render pass
     * @internal
     */
    this._touched = 0;
    /** @internal */
    this._updateID = 1;
    this._dataInt32 = null;
    /**
     * should the GPU buffer be shrunk when the data becomes smaller?
     * changing this will cause the buffer to be destroyed and a new one created on the GPU
     * this can be expensive, especially if the buffer is already big enough!
     * setting this to false will prevent the buffer from being shrunk. This will yield better performance
     * if you are constantly setting data that is changing size often.
     * @default true
     */
    this.shrinkToFit = true;
    /**
     * Has the buffer been destroyed?
     * @readonly
     */
    this.destroyed = false;
    if (data instanceof Array) {
      data = new Float32Array(data);
    }
    this._data = data;
    size ?? (size = data?.byteLength);
    const mappedAtCreation = !!data;
    this.descriptor = {
      size,
      usage,
      mappedAtCreation,
      label
    };
    this.shrinkToFit = shrinkToFit ?? true;
  }
  /** the data in the buffer */
  get data() {
    return this._data;
  }
  set data(value) {
    this.setDataWithSize(value, value.length, true);
  }
  get dataInt32() {
    if (!this._dataInt32) {
      this._dataInt32 = new Int32Array(this.data.buffer);
    }
    return this._dataInt32;
  }
  /** whether the buffer is static or not */
  get static() {
    return !!(this.descriptor.usage & BufferUsage.STATIC);
  }
  set static(value) {
    if (value) {
      this.descriptor.usage |= BufferUsage.STATIC;
    } else {
      this.descriptor.usage &= ~BufferUsage.STATIC;
    }
  }
  /**
   * Sets the data in the buffer to the given value. This will immediately update the buffer on the GPU.
   * If you only want to update a subset of the buffer, you can pass in the size of the data.
   * @param value - the data to set
   * @param size - the size of the data in bytes
   * @param syncGPU - should the buffer be updated on the GPU immediately?
   */
  setDataWithSize(value, size, syncGPU) {
    this._updateID++;
    this._updateSize = size * value.BYTES_PER_ELEMENT;
    if (this._data === value) {
      if (syncGPU) this.emit("update", this);
      return;
    }
    const oldData = this._data;
    this._data = value;
    this._dataInt32 = null;
    if (!oldData || oldData.length !== value.length) {
      if (!this.shrinkToFit && oldData && value.byteLength < oldData.byteLength) {
        if (syncGPU) this.emit("update", this);
      } else {
        this.descriptor.size = value.byteLength;
        this._resourceId = uid("resource");
        this.emit("change", this);
      }
      return;
    }
    if (syncGPU) this.emit("update", this);
  }
  /**
   * updates the buffer on the GPU to reflect the data in the buffer.
   * By default it will update the entire buffer. If you only want to update a subset of the buffer,
   * you can pass in the size of the buffer to update.
   * @param sizeInBytes - the new size of the buffer in bytes
   */
  update(sizeInBytes) {
    this._updateSize = sizeInBytes ?? this._updateSize;
    this._updateID++;
    this.emit("update", this);
  }
  /** Unloads the buffer from the GPU */
  unload() {
    this.emit("unload", this);
    for (const key in this._gpuData) {
      this._gpuData[key]?.destroy();
    }
    this._gpuData = /* @__PURE__ */ Object.create(null);
  }
  /** Destroys the buffer */
  destroy() {
    this.destroyed = true;
    this.unload();
    this.emit("destroy", this);
    this.emit("change", this);
    this._data = null;
    this.descriptor = null;
    this.removeAllListeners();
  }
}

export { Buffer };
//# sourceMappingURL=Buffer.mjs.map
