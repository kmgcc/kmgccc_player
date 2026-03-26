"use strict";
function definedProps(obj) {
  const result = {};
  for (const key in obj) {
    if (obj[key] !== void 0) {
      result[key] = obj[key];
    }
  }
  return result;
}

export { definedProps };
//# sourceMappingURL=definedProps.mjs.map
