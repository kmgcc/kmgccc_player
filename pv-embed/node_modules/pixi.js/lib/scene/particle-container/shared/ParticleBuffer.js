'use strict';

var Buffer = require('../../../rendering/renderers/shared/buffer/Buffer.js');
var _const = require('../../../rendering/renderers/shared/buffer/const.js');
var Geometry = require('../../../rendering/renderers/shared/geometry/Geometry.js');
var getAttributeInfoFromFormat = require('../../../rendering/renderers/shared/geometry/utils/getAttributeInfoFromFormat.js');
var ViewableBuffer = require('../../../utils/data/ViewableBuffer.js');
var createIndicesForQuads = require('./utils/createIndicesForQuads.js');
var generateParticleUpdateFunction = require('./utils/generateParticleUpdateFunction.js');

"use strict";
class ParticleBuffer {
  constructor(options) {
    this._size = 0;
    this._generateParticleUpdateCache = {};
    const size = this._size = options.size ?? 1e3;
    const properties = options.properties;
    let staticVertexSize = 0;
    let dynamicVertexSize = 0;
    for (const i in properties) {
      const property = properties[i];
      const attributeInfo = getAttributeInfoFromFormat.getAttributeInfoFromFormat(property.format);
      if (property.dynamic) {
        dynamicVertexSize += attributeInfo.stride;
      } else {
        staticVertexSize += attributeInfo.stride;
      }
    }
    this._dynamicStride = dynamicVertexSize / 4;
    this._staticStride = staticVertexSize / 4;
    this.staticAttributeBuffer = new ViewableBuffer.ViewableBuffer(size * 4 * staticVertexSize);
    this.dynamicAttributeBuffer = new ViewableBuffer.ViewableBuffer(size * 4 * dynamicVertexSize);
    this.indexBuffer = createIndicesForQuads.createIndicesForQuads(size);
    const geometry = new Geometry.Geometry();
    let dynamicOffset = 0;
    let staticOffset = 0;
    this._staticBuffer = new Buffer.Buffer({
      data: new Float32Array(1),
      label: "static-particle-buffer",
      shrinkToFit: false,
      usage: _const.BufferUsage.VERTEX | _const.BufferUsage.COPY_DST
    });
    this._dynamicBuffer = new Buffer.Buffer({
      data: new Float32Array(1),
      label: "dynamic-particle-buffer",
      shrinkToFit: false,
      usage: _const.BufferUsage.VERTEX | _const.BufferUsage.COPY_DST
    });
    for (const i in properties) {
      const property = properties[i];
      const attributeInfo = getAttributeInfoFromFormat.getAttributeInfoFromFormat(property.format);
      if (property.dynamic) {
        geometry.addAttribute(property.attributeName, {
          buffer: this._dynamicBuffer,
          stride: this._dynamicStride * 4,
          offset: dynamicOffset * 4,
          format: property.format
        });
        dynamicOffset += attributeInfo.size;
      } else {
        geometry.addAttribute(property.attributeName, {
          buffer: this._staticBuffer,
          stride: this._staticStride * 4,
          offset: staticOffset * 4,
          format: property.format
        });
        staticOffset += attributeInfo.size;
      }
    }
    geometry.addIndex(this.indexBuffer);
    const uploadFunction = this.getParticleUpdate(properties);
    this._dynamicUpload = uploadFunction.dynamicUpdate;
    this._staticUpload = uploadFunction.staticUpdate;
    this.geometry = geometry;
  }
  getParticleUpdate(properties) {
    const key = getParticleSyncKey(properties);
    if (this._generateParticleUpdateCache[key]) {
      return this._generateParticleUpdateCache[key];
    }
    this._generateParticleUpdateCache[key] = this.generateParticleUpdate(properties);
    return this._generateParticleUpdateCache[key];
  }
  generateParticleUpdate(properties) {
    return generateParticleUpdateFunction.generateParticleUpdateFunction(properties);
  }
  update(particles, uploadStatic) {
    if (particles.length > this._size) {
      uploadStatic = true;
      this._size = Math.max(particles.length, this._size * 1.5 | 0);
      this.staticAttributeBuffer = new ViewableBuffer.ViewableBuffer(this._size * this._staticStride * 4 * 4);
      this.dynamicAttributeBuffer = new ViewableBuffer.ViewableBuffer(this._size * this._dynamicStride * 4 * 4);
      this.indexBuffer = createIndicesForQuads.createIndicesForQuads(this._size);
      this.geometry.indexBuffer.setDataWithSize(
        this.indexBuffer,
        this.indexBuffer.byteLength,
        true
      );
    }
    const dynamicAttributeBuffer = this.dynamicAttributeBuffer;
    this._dynamicUpload(particles, dynamicAttributeBuffer.float32View, dynamicAttributeBuffer.uint32View);
    this._dynamicBuffer.setDataWithSize(
      this.dynamicAttributeBuffer.float32View,
      particles.length * this._dynamicStride * 4,
      true
    );
    if (uploadStatic) {
      const staticAttributeBuffer = this.staticAttributeBuffer;
      this._staticUpload(particles, staticAttributeBuffer.float32View, staticAttributeBuffer.uint32View);
      this._staticBuffer.setDataWithSize(
        staticAttributeBuffer.float32View,
        particles.length * this._staticStride * 4,
        true
      );
    }
  }
  destroy() {
    this._staticBuffer.destroy();
    this._dynamicBuffer.destroy();
    this.geometry.destroy();
  }
}
function getParticleSyncKey(properties) {
  const keyGen = [];
  for (const key in properties) {
    const property = properties[key];
    keyGen.push(key, property.code, property.dynamic ? "d" : "s");
  }
  return keyGen.join("_");
}

exports.ParticleBuffer = ParticleBuffer;
//# sourceMappingURL=ParticleBuffer.js.map
