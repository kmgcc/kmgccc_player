'use strict';

"use strict";
function parseSVGFloatAttribute(svg, id, defaultValue) {
  const value = svg.getAttribute(id);
  return value ? Number(value) : defaultValue;
}

exports.parseSVGFloatAttribute = parseSVGFloatAttribute;
//# sourceMappingURL=parseSVGFloatAttribute.js.map
