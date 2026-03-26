"use strict";
function assignWithIgnore(target, options, ignore = {}) {
  for (const key in options) {
    if (!ignore[key] && options[key] !== void 0) {
      target[key] = options[key];
    }
  }
}

export { assignWithIgnore };
//# sourceMappingURL=assignWithIgnore.mjs.map
