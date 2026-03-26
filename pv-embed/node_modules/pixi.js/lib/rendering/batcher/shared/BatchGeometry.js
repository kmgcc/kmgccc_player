'use strict';

var Buffer = require('../../renderers/shared/buffer/Buffer.js');
var _const = require('../../renderers/shared/buffer/const.js');
var Geometry = require('../../renderers/shared/geometry/Geometry.js');

"use strict";
const placeHolderBufferData = new Float32Array(1);
const placeHolderIndexData = new Uint32Array(1);
class BatchGeometry extends Geometry.Geometry {
  constructor() {
    const vertexSize = 6;
    const attributeBuffer = new Buffer.Buffer({
      data: placeHolderBufferData,
      label: "attribute-batch-buffer",
      usage: _const.BufferUsage.VERTEX | _const.BufferUsage.COPY_DST,
      shrinkToFit: false
    });
    const indexBuffer = new Buffer.Buffer({
      data: placeHolderIndexData,
      label: "index-batch-buffer",
      usage: _const.BufferUsage.INDEX | _const.BufferUsage.COPY_DST,
      // | BufferUsage.STATIC,
      shrinkToFit: false
    });
    const stride = vertexSize * 4;
    super({
      attributes: {
        aPosition: {
          buffer: attributeBuffer,
          format: "float32x2",
          stride,
          offset: 0
        },
        aUV: {
          buffer: attributeBuffer,
          format: "float32x2",
          stride,
          offset: 2 * 4
        },
        aColor: {
          buffer: attributeBuffer,
          format: "unorm8x4",
          stride,
          offset: 4 * 4
        },
        aTextureIdAndRound: {
          buffer: attributeBuffer,
          format: "uint16x2",
          stride,
          offset: 5 * 4
        }
      },
      indexBuffer
    });
  }
}

exports.BatchGeometry = BatchGeometry;
//# sourceMappingURL=BatchGeometry.js.map
