'use strict';

var warn = require('../../../../../utils/logging/warn.js');
var getAttributeInfoFromFormat = require('../../../shared/geometry/utils/getAttributeInfoFromFormat.js');

"use strict";
function ensureAttributes(geometry, extractedData) {
  for (const i in geometry.attributes) {
    const attribute = geometry.attributes[i];
    const attributeData = extractedData[i];
    if (attributeData) {
      attribute.format ?? (attribute.format = attributeData.format);
      attribute.offset ?? (attribute.offset = attributeData.offset);
      attribute.instance ?? (attribute.instance = attributeData.instance);
    } else {
      warn.warn(`Attribute ${i} is not present in the shader, but is present in the geometry. Unable to infer attribute details.`);
    }
  }
  ensureStartAndStride(geometry);
}
function ensureStartAndStride(geometry) {
  const { buffers, attributes } = geometry;
  const tempStride = {};
  const tempStart = {};
  for (const j in buffers) {
    const buffer = buffers[j];
    tempStride[buffer.uid] = 0;
    tempStart[buffer.uid] = 0;
  }
  for (const j in attributes) {
    const attribute = attributes[j];
    tempStride[attribute.buffer.uid] += getAttributeInfoFromFormat.getAttributeInfoFromFormat(attribute.format).stride;
  }
  for (const j in attributes) {
    const attribute = attributes[j];
    attribute.stride ?? (attribute.stride = tempStride[attribute.buffer.uid]);
    attribute.start ?? (attribute.start = tempStart[attribute.buffer.uid]);
    tempStart[attribute.buffer.uid] += getAttributeInfoFromFormat.getAttributeInfoFromFormat(attribute.format).stride;
  }
}

exports.ensureAttributes = ensureAttributes;
//# sourceMappingURL=ensureAttributes.js.map
