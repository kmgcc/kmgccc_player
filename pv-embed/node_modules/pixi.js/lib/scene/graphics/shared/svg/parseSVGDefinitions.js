'use strict';

var Color = require('../../../../color/Color.js');
var warn = require('../../../../utils/logging/warn.js');
var FillGradient = require('../fill/FillGradient.js');
var parseSVGFloatAttribute = require('./parseSVGFloatAttribute.js');

"use strict";
function parseSVGDefinitions(svg, session) {
  const definitions = svg.querySelectorAll("defs");
  for (let i = 0; i < definitions.length; i++) {
    const definition = definitions[i];
    for (let j = 0; j < definition.children.length; j++) {
      const child = definition.children[j];
      switch (child.nodeName.toLowerCase()) {
        case "lineargradient":
          session.defs[child.id] = parseLinearGradient(child);
          break;
        case "radialgradient":
          session.defs[child.id] = parseRadialGradient(child);
          break;
        default:
          break;
      }
    }
  }
}
function parseLinearGradient(child) {
  const x0 = parseSVGFloatAttribute.parseSVGFloatAttribute(child, "x1", 0);
  const y0 = parseSVGFloatAttribute.parseSVGFloatAttribute(child, "y1", 0);
  const x1 = parseSVGFloatAttribute.parseSVGFloatAttribute(child, "x2", 1);
  const y1 = parseSVGFloatAttribute.parseSVGFloatAttribute(child, "y2", 0);
  const gradientUnit = child.getAttribute("gradientUnits") || "objectBoundingBox";
  const gradient = new FillGradient.FillGradient(
    x0,
    y0,
    x1,
    y1,
    gradientUnit === "objectBoundingBox" ? "local" : "global"
  );
  for (let k = 0; k < child.children.length; k++) {
    const stop = child.children[k];
    const offset = parseSVGFloatAttribute.parseSVGFloatAttribute(stop, "offset", 0);
    const color = Color.Color.shared.setValue(stop.getAttribute("stop-color")).toNumber();
    gradient.addColorStop(offset, color);
  }
  return gradient;
}
function parseRadialGradient(_child) {
  warn.warn("[SVG Parser] Radial gradients are not yet supported");
  return new FillGradient.FillGradient(0, 0, 1, 0);
}

exports.parseSVGDefinitions = parseSVGDefinitions;
//# sourceMappingURL=parseSVGDefinitions.js.map
