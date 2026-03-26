"use strict";
function parseSVGFloatAttribute(svg, id, defaultValue) {
  const value = svg.getAttribute(id);
  return value ? Number(value) : defaultValue;
}

export { parseSVGFloatAttribute };
//# sourceMappingURL=parseSVGFloatAttribute.mjs.map
