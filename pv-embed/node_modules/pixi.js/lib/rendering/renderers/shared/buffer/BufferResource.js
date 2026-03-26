'use strict';

var EventEmitter = require('eventemitter3');
var uid = require('../../../../utils/data/uid.js');

"use strict";
class BufferResource extends EventEmitter {
  /**
   * Create a new Buffer Resource.
   * @param options - The options for the buffer resource
   * @param options.buffer - The underlying buffer that this resource is using
   * @param options.offset - The offset of the buffer this resource is using.
   * If not provided, then it will use the offset of the buffer.
   * @param options.size - The size of the buffer this resource is using.
   * If not provided, then it will use the size of the buffer.
   */
  constructor({ buffer, offset, size }) {
    super();
    /**
     * emits when the underlying buffer has changed shape (i.e. resized)
     * letting the renderer know that it needs to discard the old buffer on the GPU and create a new one
     * @event change
     */
    /** a unique id for this uniform group used through the renderer */
    this.uid = uid.uid("buffer");
    /**
     * a resource type, used to identify how to handle it when its in a bind group / shader resource
     * @internal
     */
    this._resourceType = "bufferResource";
    /**
     * used internally to know if a uniform group was used in the last render pass
     * @internal
     */
    this._touched = 0;
    /**
     * the resource id used internally by the renderer to build bind group keys
     * @internal
     */
    this._resourceId = uid.uid("resource");
    /**
     * A cheeky hint to the GL renderer to let it know this is a BufferResource
     * @internal
     */
    this._bufferResource = true;
    /**
     * Has the Buffer resource been destroyed?
     * @readonly
     */
    this.destroyed = false;
    this.buffer = buffer;
    this.offset = offset | 0;
    this.size = size;
    this.buffer.on("change", this.onBufferChange, this);
  }
  onBufferChange() {
    this._resourceId = uid.uid("resource");
    this.emit("change", this);
  }
  /**
   * Destroys this resource. Make sure the underlying buffer is not used anywhere else
   * if you want to destroy it as well, or code will explode
   * @param destroyBuffer - Should the underlying buffer be destroyed as well?
   */
  destroy(destroyBuffer = false) {
    this.destroyed = true;
    if (destroyBuffer) {
      this.buffer.destroy();
    }
    this.emit("change", this);
    this.buffer = null;
    this.removeAllListeners();
  }
}

exports.BufferResource = BufferResource;
//# sourceMappingURL=BufferResource.js.map
