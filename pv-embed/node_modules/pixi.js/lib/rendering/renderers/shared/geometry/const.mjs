import { deprecation, v8_0_0 } from '../../../../utils/logging/deprecation.mjs';

"use strict";
const DEPRECATED_DRAW_MODES = {
  POINTS: "point-list",
  LINES: "line-list",
  LINE_STRIP: "line-strip",
  TRIANGLES: "triangle-list",
  TRIANGLE_STRIP: "triangle-strip"
};
const DRAW_MODES = new Proxy(DEPRECATED_DRAW_MODES, {
  get(target, prop) {
    deprecation(v8_0_0, `DRAW_MODES.${prop} is deprecated, use '${DEPRECATED_DRAW_MODES[prop]}' instead`);
    return target[prop];
  }
});

export { DRAW_MODES };
//# sourceMappingURL=const.mjs.map
