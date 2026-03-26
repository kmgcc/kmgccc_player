"use strict";
function stripVersion(src, isES300) {
  if (!isES300) return src;
  return src.replace("#version 300 es", "");
}

export { stripVersion };
//# sourceMappingURL=stripVersion.mjs.map
