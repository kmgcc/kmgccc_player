'use strict';

var Color = require('../../../../color/Color.js');
var extractSvgUrlId = require('./utils/extractSvgUrlId.js');

"use strict";
const styleAttributes = {
  // Fill properties
  fill: { type: "paint", default: 0 },
  // Fill color/gradient
  "fill-opacity": { type: "number", default: 1 },
  // Fill transparency
  // Stroke properties
  stroke: { type: "paint", default: 0 },
  // Stroke color/gradient
  "stroke-width": { type: "number", default: 1 },
  // Width of stroke
  "stroke-opacity": { type: "number", default: 1 },
  // Stroke transparency
  "stroke-linecap": { type: "string", default: "butt" },
  // End cap style: butt, round, square
  "stroke-linejoin": { type: "string", default: "miter" },
  // Join style: miter, round, bevel
  "stroke-miterlimit": { type: "number", default: 10 },
  // Limit on miter join sharpness
  "stroke-dasharray": { type: "string", default: "none" },
  // Dash pattern
  "stroke-dashoffset": { type: "number", default: 0 },
  // Offset for dash pattern
  // Global properties
  opacity: { type: "number", default: 1 }
  // Overall opacity
};
function parseSVGStyle(svg, session) {
  const style = svg.getAttribute("style");
  const strokeStyle = {};
  const fillStyle = {};
  const result = {
    strokeStyle,
    fillStyle,
    useFill: false,
    useStroke: false
  };
  for (const key in styleAttributes) {
    const attribute = svg.getAttribute(key);
    if (attribute) {
      parseAttribute(session, result, key, attribute.trim());
    }
  }
  if (style) {
    const styleParts = style.split(";");
    for (let i = 0; i < styleParts.length; i++) {
      const stylePart = styleParts[i].trim();
      const [key, value] = stylePart.split(":");
      if (styleAttributes[key]) {
        parseAttribute(session, result, key, value.trim());
      }
    }
  }
  return {
    strokeStyle: result.useStroke ? strokeStyle : null,
    fillStyle: result.useFill ? fillStyle : null,
    useFill: result.useFill,
    useStroke: result.useStroke
  };
}
function parseAttribute(session, result, id, value) {
  switch (id) {
    case "stroke":
      if (value !== "none") {
        if (value.startsWith("url(")) {
          const id2 = extractSvgUrlId.extractSvgUrlId(value);
          result.strokeStyle.fill = session.defs[id2];
        } else {
          result.strokeStyle.color = Color.Color.shared.setValue(value).toNumber();
        }
        result.useStroke = true;
      }
      break;
    case "stroke-width":
      result.strokeStyle.width = Number(value);
      break;
    case "fill":
      if (value !== "none") {
        if (value.startsWith("url(")) {
          const id2 = extractSvgUrlId.extractSvgUrlId(value);
          result.fillStyle.fill = session.defs[id2];
        } else {
          result.fillStyle.color = Color.Color.shared.setValue(value).toNumber();
        }
        result.useFill = true;
      }
      break;
    case "fill-opacity":
      result.fillStyle.alpha = Number(value);
      break;
    case "stroke-opacity":
      result.strokeStyle.alpha = Number(value);
      break;
    case "opacity":
      result.fillStyle.alpha = Number(value);
      result.strokeStyle.alpha = Number(value);
      break;
  }
}

exports.parseSVGStyle = parseSVGStyle;
exports.styleAttributes = styleAttributes;
//# sourceMappingURL=parseSVGStyle.js.map
