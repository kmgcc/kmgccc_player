'use strict';

"use strict";
function extractSvgUrlId(url) {
  const match = url.match(/url\s*\(\s*['"]?\s*#([^'"\s)]+)\s*['"]?\s*\)/i);
  return match ? match[1] : "";
}

exports.extractSvgUrlId = extractSvgUrlId;
//# sourceMappingURL=extractSvgUrlId.js.map
