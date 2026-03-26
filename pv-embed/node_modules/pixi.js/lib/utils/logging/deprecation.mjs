"use strict";
const warnings = /* @__PURE__ */ new Set();
const v8_0_0 = "8.0.0";
const v8_3_4 = "8.3.4";
const deprecationState = {
  quiet: false,
  noColor: false
};
const deprecation = ((version, message, ignoreDepth = 3) => {
  if (deprecationState.quiet || warnings.has(message)) return;
  let stack = new Error().stack;
  const deprecationMessage = `${message}
Deprecated since v${version}`;
  const useGroup = typeof console.groupCollapsed === "function" && !deprecationState.noColor;
  if (typeof stack === "undefined") {
    console.warn("PixiJS Deprecation Warning: ", deprecationMessage);
  } else {
    stack = stack.split("\n").splice(ignoreDepth).join("\n");
    if (useGroup) {
      console.groupCollapsed(
        "%cPixiJS Deprecation Warning: %c%s",
        "color:#614108;background:#fffbe6",
        "font-weight:normal;color:#614108;background:#fffbe6",
        deprecationMessage
      );
      console.warn(stack);
      console.groupEnd();
    } else {
      console.warn("PixiJS Deprecation Warning: ", deprecationMessage);
      console.warn(stack);
    }
  }
  warnings.add(message);
});
Object.defineProperties(deprecation, {
  quiet: {
    get: () => deprecationState.quiet,
    set: (value) => {
      deprecationState.quiet = value;
    },
    enumerable: true,
    configurable: false
  },
  noColor: {
    get: () => deprecationState.noColor,
    set: (value) => {
      deprecationState.noColor = value;
    },
    enumerable: true,
    configurable: false
  }
});

export { deprecation, v8_0_0, v8_3_4 };
//# sourceMappingURL=deprecation.mjs.map
