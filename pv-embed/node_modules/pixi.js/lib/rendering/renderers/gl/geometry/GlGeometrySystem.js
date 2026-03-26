'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var GCManagedHash = require('../../../../utils/data/GCManagedHash.js');
var getAttributeInfoFromFormat = require('../../shared/geometry/utils/getAttributeInfoFromFormat.js');
var ensureAttributes = require('../shader/program/ensureAttributes.js');
var getGlTypeFromFormat = require('./utils/getGlTypeFromFormat.js');

"use strict";
const topologyToGlMap = {
  "point-list": 0,
  "line-list": 1,
  "line-strip": 3,
  "triangle-list": 4,
  "triangle-strip": 5
};
class GlGeometryGpuData {
  constructor() {
    this.vaoCache = /* @__PURE__ */ Object.create(null);
  }
  destroy() {
    this.vaoCache = /* @__PURE__ */ Object.create(null);
  }
}
class GlGeometrySystem {
  /** @param renderer - The renderer this System works for. */
  constructor(renderer) {
    this._renderer = renderer;
    this._activeGeometry = null;
    this._activeVao = null;
    this.hasVao = true;
    this.hasInstance = true;
    this._managedGeometries = new GCManagedHash.GCManagedHash({
      renderer,
      type: "resource",
      onUnload: this.onGeometryUnload.bind(this),
      name: "glGeometry"
    });
  }
  /** Sets up the renderer context and necessary buffers. */
  contextChange() {
    const gl = this.gl = this._renderer.gl;
    if (!this._renderer.context.supports.vertexArrayObject) {
      throw new Error("[PixiJS] Vertex Array Objects are not supported on this device");
    }
    this.destroyAll(true);
    const nativeVaoExtension = this._renderer.context.extensions.vertexArrayObject;
    if (nativeVaoExtension) {
      gl.createVertexArray = () => nativeVaoExtension.createVertexArrayOES();
      gl.bindVertexArray = (vao) => nativeVaoExtension.bindVertexArrayOES(vao);
      gl.deleteVertexArray = (vao) => nativeVaoExtension.deleteVertexArrayOES(vao);
    }
    const nativeInstancedExtension = this._renderer.context.extensions.vertexAttribDivisorANGLE;
    if (nativeInstancedExtension) {
      gl.drawArraysInstanced = (a, b, c, d) => {
        nativeInstancedExtension.drawArraysInstancedANGLE(a, b, c, d);
      };
      gl.drawElementsInstanced = (a, b, c, d, e) => {
        nativeInstancedExtension.drawElementsInstancedANGLE(a, b, c, d, e);
      };
      gl.vertexAttribDivisor = (a, b) => nativeInstancedExtension.vertexAttribDivisorANGLE(a, b);
    }
    this._activeGeometry = null;
    this._activeVao = null;
  }
  /**
   * Binds geometry so that is can be drawn. Creating a Vao if required
   * @param geometry - Instance of geometry to bind.
   * @param program - Instance of program to use vao for.
   */
  bind(geometry, program) {
    const gl = this.gl;
    this._activeGeometry = geometry;
    const vao = this.getVao(geometry, program);
    if (this._activeVao !== vao) {
      this._activeVao = vao;
      gl.bindVertexArray(vao);
    }
    this.updateBuffers();
  }
  /** Reset and unbind any active VAO and geometry. */
  resetState() {
    this.unbind();
  }
  /** Update buffers of the currently bound geometry. */
  updateBuffers() {
    const geometry = this._activeGeometry;
    const bufferSystem = this._renderer.buffer;
    for (let i = 0; i < geometry.buffers.length; i++) {
      const buffer = geometry.buffers[i];
      bufferSystem.updateBuffer(buffer);
    }
    geometry._gcLastUsed = this._renderer.gc.now;
  }
  /**
   * Check compatibility between a geometry and a program
   * @param geometry - Geometry instance.
   * @param program - Program instance.
   */
  checkCompatibility(geometry, program) {
    const geometryAttributes = geometry.attributes;
    const shaderAttributes = program._attributeData;
    for (const j in shaderAttributes) {
      if (!geometryAttributes[j]) {
        throw new Error(`shader and geometry incompatible, geometry missing the "${j}" attribute`);
      }
    }
  }
  /**
   * Takes a geometry and program and generates a unique signature for them.
   * @param geometry - To get signature from.
   * @param program - To test geometry against.
   * @returns - Unique signature of the geometry and program
   */
  getSignature(geometry, program) {
    const attribs = geometry.attributes;
    const shaderAttributes = program._attributeData;
    const strings = ["g", geometry.uid];
    for (const i in attribs) {
      if (shaderAttributes[i]) {
        strings.push(i, shaderAttributes[i].location);
      }
    }
    return strings.join("-");
  }
  getVao(geometry, program) {
    return geometry._gpuData[this._renderer.uid]?.vaoCache[program._key] || this.initGeometryVao(geometry, program);
  }
  /**
   * Creates or gets Vao with the same structure as the geometry and stores it on the geometry.
   * If vao is created, it is bound automatically. We use a shader to infer what and how to set up the
   * attribute locations.
   * @param geometry - Instance of geometry to to generate Vao for.
   * @param program
   * @param _incRefCount - Increment refCount of all geometry buffers.
   */
  initGeometryVao(geometry, program, _incRefCount = true) {
    const gl = this._renderer.gl;
    const bufferSystem = this._renderer.buffer;
    this._renderer.shader._getProgramData(program);
    this.checkCompatibility(geometry, program);
    const signature = this.getSignature(geometry, program);
    let gpuData = geometry._gpuData[this._renderer.uid];
    if (!gpuData) {
      gpuData = new GlGeometryGpuData();
      geometry._gpuData[this._renderer.uid] = gpuData;
      this._managedGeometries.add(geometry);
    }
    const vaoObjectHash = gpuData.vaoCache;
    let vao = vaoObjectHash[signature];
    if (vao) {
      vaoObjectHash[program._key] = vao;
      return vao;
    }
    ensureAttributes.ensureAttributes(geometry, program._attributeData);
    const buffers = geometry.buffers;
    vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    for (let i = 0; i < buffers.length; i++) {
      const buffer = buffers[i];
      bufferSystem.bind(buffer);
    }
    this.activateVao(geometry, program);
    vaoObjectHash[program._key] = vao;
    vaoObjectHash[signature] = vao;
    gl.bindVertexArray(null);
    return vao;
  }
  onGeometryUnload(geometry, contextLost = false) {
    const gpuData = geometry._gpuData[this._renderer.uid];
    if (!gpuData) return;
    const vaoCache = gpuData.vaoCache;
    if (!contextLost) {
      for (const i in vaoCache) {
        if (this._activeVao !== vaoCache[i]) {
          this.resetState();
        }
        this.gl.deleteVertexArray(vaoCache[i]);
      }
    }
  }
  /**
   * Dispose all WebGL resources of all managed geometries.
   * @param [contextLost=false] - If context was lost, we suppress `gl.delete` calls
   */
  destroyAll(contextLost = false) {
    this._managedGeometries.removeAll(contextLost);
  }
  /**
   * Activate vertex array object.
   * @param geometry - Geometry instance.
   * @param program - Shader program instance.
   */
  activateVao(geometry, program) {
    const gl = this._renderer.gl;
    const bufferSystem = this._renderer.buffer;
    const attributes = geometry.attributes;
    if (geometry.indexBuffer) {
      bufferSystem.bind(geometry.indexBuffer);
    }
    let lastBuffer = null;
    for (const j in attributes) {
      const attribute = attributes[j];
      const buffer = attribute.buffer;
      const glBuffer = bufferSystem.getGlBuffer(buffer);
      const programAttrib = program._attributeData[j];
      if (programAttrib) {
        if (lastBuffer !== glBuffer) {
          bufferSystem.bind(buffer);
          lastBuffer = glBuffer;
        }
        const location = programAttrib.location;
        gl.enableVertexAttribArray(location);
        const attributeInfo = getAttributeInfoFromFormat.getAttributeInfoFromFormat(attribute.format);
        const type = getGlTypeFromFormat.getGlTypeFromFormat(attribute.format);
        if (programAttrib.format?.substring(1, 4) === "int") {
          gl.vertexAttribIPointer(
            location,
            attributeInfo.size,
            type,
            attribute.stride,
            attribute.offset
          );
        } else {
          gl.vertexAttribPointer(
            location,
            attributeInfo.size,
            type,
            attributeInfo.normalised,
            attribute.stride,
            attribute.offset
          );
        }
        if (attribute.instance) {
          if (this.hasInstance) {
            const divisor = attribute.divisor ?? 1;
            gl.vertexAttribDivisor(location, divisor);
          } else {
            throw new Error("geometry error, GPU Instancing is not supported on this device");
          }
        }
      }
    }
  }
  /**
   * Draws the currently bound geometry.
   * @param topology - The type primitive to render.
   * @param size - The number of elements to be rendered. If not specified, all vertices after the
   *  starting vertex will be drawn.
   * @param start - The starting vertex in the geometry to start drawing from. If not specified,
   *  drawing will start from the first vertex.
   * @param instanceCount - The number of instances of the set of elements to execute. If not specified,
   *  all instances will be drawn.
   * @returns This instance of the geometry system.
   */
  draw(topology, size, start, instanceCount) {
    const { gl } = this._renderer;
    const geometry = this._activeGeometry;
    const glTopology = topologyToGlMap[topology || geometry.topology];
    instanceCount ?? (instanceCount = geometry.instanceCount);
    if (geometry.indexBuffer) {
      const byteSize = geometry.indexBuffer.data.BYTES_PER_ELEMENT;
      const glType = byteSize === 2 ? gl.UNSIGNED_SHORT : gl.UNSIGNED_INT;
      if (instanceCount !== 1) {
        gl.drawElementsInstanced(glTopology, size || geometry.indexBuffer.data.length, glType, (start || 0) * byteSize, instanceCount);
      } else {
        gl.drawElements(glTopology, size || geometry.indexBuffer.data.length, glType, (start || 0) * byteSize);
      }
    } else if (instanceCount !== 1) {
      gl.drawArraysInstanced(glTopology, start || 0, size || geometry.getSize(), instanceCount);
    } else {
      gl.drawArrays(glTopology, start || 0, size || geometry.getSize());
    }
    return this;
  }
  /** Unbind/reset everything. */
  unbind() {
    this.gl.bindVertexArray(null);
    this._activeVao = null;
    this._activeGeometry = null;
  }
  destroy() {
    this._managedGeometries.destroy();
    this._renderer = null;
    this.gl = null;
    this._activeVao = null;
    this._activeGeometry = null;
  }
}
/** @ignore */
GlGeometrySystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "geometry"
};

exports.GlGeometryGpuData = GlGeometryGpuData;
exports.GlGeometrySystem = GlGeometrySystem;
//# sourceMappingURL=GlGeometrySystem.js.map
