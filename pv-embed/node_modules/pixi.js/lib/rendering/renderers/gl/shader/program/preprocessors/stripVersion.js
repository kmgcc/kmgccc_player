'use strict';

"use strict";
function stripVersion(src, isES300) {
  if (!isES300) return src;
  return src.replace("#version 300 es", "");
}

exports.stripVersion = stripVersion;
//# sourceMappingURL=stripVersion.js.map
