'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var GCManagedHash = require('../../../../utils/data/GCManagedHash.js');
var _const = require('../../shared/buffer/const.js');
var _const$1 = require('./const.js');
var GlBuffer = require('./GlBuffer.js');

"use strict";
class GlBufferSystem {
  /**
   * @param {Renderer} renderer - The renderer this System works for.
   */
  constructor(renderer) {
    /** Cache keeping track of the base bound buffer bases */
    this._boundBufferBases = /* @__PURE__ */ Object.create(null);
    this._minBaseLocation = 0;
    this._nextBindBaseIndex = this._minBaseLocation;
    this._bindCallId = 0;
    this._renderer = renderer;
    this._managedBuffers = new GCManagedHash.GCManagedHash({
      renderer,
      type: "resource",
      onUnload: this.onBufferUnload.bind(this),
      name: "glBuffer"
    });
  }
  /** @ignore */
  destroy() {
    this._managedBuffers.destroy();
    this._renderer = null;
    this._gl = null;
    this._boundBufferBases = {};
  }
  /** Sets up the renderer context and necessary buffers. */
  contextChange() {
    this._gl = this._renderer.gl;
    this.destroyAll(true);
    this._maxBindings = this._renderer.limits.maxUniformBindings;
  }
  getGlBuffer(buffer) {
    buffer._gcLastUsed = this._renderer.gc.now;
    return buffer._gpuData[this._renderer.uid] || this.createGLBuffer(buffer);
  }
  /**
   * This binds specified buffer. On first run, it will create the webGL buffers for the context too
   * @param buffer - the buffer to bind to the renderer
   */
  bind(buffer) {
    const { _gl: gl } = this;
    const glBuffer = this.getGlBuffer(buffer);
    gl.bindBuffer(glBuffer.type, glBuffer.buffer);
  }
  /**
   * Binds an uniform buffer to at the given index.
   *
   * A cache is used so a buffer will not be bound again if already bound.
   * @param glBuffer - the buffer to bind
   * @param index - the base index to bind it to.
   */
  bindBufferBase(glBuffer, index) {
    const { _gl: gl } = this;
    if (this._boundBufferBases[index] !== glBuffer) {
      this._boundBufferBases[index] = glBuffer;
      glBuffer._lastBindBaseLocation = index;
      gl.bindBufferBase(gl.UNIFORM_BUFFER, index, glBuffer.buffer);
    }
  }
  nextBindBase(hasTransformFeedback) {
    this._bindCallId++;
    this._minBaseLocation = 0;
    if (hasTransformFeedback) {
      this._boundBufferBases[0] = null;
      this._minBaseLocation = 1;
      if (this._nextBindBaseIndex < 1) {
        this._nextBindBaseIndex = 1;
      }
    }
  }
  freeLocationForBufferBase(glBuffer) {
    let freeIndex = this.getLastBindBaseLocation(glBuffer);
    if (freeIndex >= this._minBaseLocation) {
      glBuffer._lastBindCallId = this._bindCallId;
      return freeIndex;
    }
    let loop = 0;
    let nextIndex = this._nextBindBaseIndex;
    while (loop < 2) {
      if (nextIndex >= this._maxBindings) {
        nextIndex = this._minBaseLocation;
        loop++;
      }
      const curBuf = this._boundBufferBases[nextIndex];
      if (curBuf && curBuf._lastBindCallId === this._bindCallId) {
        nextIndex++;
        continue;
      }
      break;
    }
    freeIndex = nextIndex;
    this._nextBindBaseIndex = nextIndex + 1;
    if (loop >= 2) {
      return -1;
    }
    glBuffer._lastBindCallId = this._bindCallId;
    this._boundBufferBases[freeIndex] = null;
    return freeIndex;
  }
  getLastBindBaseLocation(glBuffer) {
    const index = glBuffer._lastBindBaseLocation;
    if (this._boundBufferBases[index] === glBuffer) {
      return index;
    }
    return -1;
  }
  /**
   * Binds a buffer whilst also binding its range.
   * This will make the buffer start from the offset supplied rather than 0 when it is read.
   * @param glBuffer - the buffer to bind
   * @param index - the base index to bind at, defaults to 0
   * @param offset - the offset to bind at (this is blocks of 256). 0 = 0, 1 = 256, 2 = 512 etc
   * @param size - the size to bind at (this is blocks of 256).
   */
  bindBufferRange(glBuffer, index, offset, size) {
    const { _gl: gl } = this;
    offset || (offset = 0);
    index || (index = 0);
    this._boundBufferBases[index] = null;
    gl.bindBufferRange(gl.UNIFORM_BUFFER, index || 0, glBuffer.buffer, offset * 256, size || 256);
  }
  /**
   * Will ensure the data in the buffer is uploaded to the GPU.
   * @param {Buffer} buffer - the buffer to update
   */
  updateBuffer(buffer) {
    const { _gl: gl } = this;
    const glBuffer = this.getGlBuffer(buffer);
    if (buffer._updateID === glBuffer.updateID) {
      return glBuffer;
    }
    glBuffer.updateID = buffer._updateID;
    gl.bindBuffer(glBuffer.type, glBuffer.buffer);
    const data = buffer.data;
    const drawType = buffer.descriptor.usage & _const.BufferUsage.STATIC ? gl.STATIC_DRAW : gl.DYNAMIC_DRAW;
    if (data) {
      if (glBuffer.byteLength >= data.byteLength) {
        gl.bufferSubData(glBuffer.type, 0, data, 0, buffer._updateSize / data.BYTES_PER_ELEMENT);
      } else {
        glBuffer.byteLength = data.byteLength;
        gl.bufferData(glBuffer.type, data, drawType);
      }
    } else {
      glBuffer.byteLength = buffer.descriptor.size;
      gl.bufferData(glBuffer.type, glBuffer.byteLength, drawType);
    }
    return glBuffer;
  }
  /**
   * dispose all WebGL resources of all managed buffers
   * @param contextLost
   */
  destroyAll(contextLost = false) {
    this._managedBuffers.removeAll(contextLost);
  }
  onBufferUnload(buffer, contextLost = false) {
    const glBuffer = buffer._gpuData[this._renderer.uid];
    if (!glBuffer) return;
    if (!contextLost) this._gl.deleteBuffer(glBuffer.buffer);
  }
  /**
   * creates and attaches a GLBuffer object tied to the current context.
   * @param buffer
   * @protected
   */
  createGLBuffer(buffer) {
    const { _gl: gl } = this;
    let type = _const$1.BUFFER_TYPE.ARRAY_BUFFER;
    if (buffer.descriptor.usage & _const.BufferUsage.INDEX) {
      type = _const$1.BUFFER_TYPE.ELEMENT_ARRAY_BUFFER;
    } else if (buffer.descriptor.usage & _const.BufferUsage.UNIFORM) {
      type = _const$1.BUFFER_TYPE.UNIFORM_BUFFER;
    }
    const glBuffer = new GlBuffer.GlBuffer(gl.createBuffer(), type);
    buffer._gpuData[this._renderer.uid] = glBuffer;
    this._managedBuffers.add(buffer);
    return glBuffer;
  }
  resetState() {
    this._boundBufferBases = /* @__PURE__ */ Object.create(null);
  }
}
/** @ignore */
GlBufferSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "buffer"
};

exports.GlBufferSystem = GlBufferSystem;
//# sourceMappingURL=GlBufferSystem.js.map
