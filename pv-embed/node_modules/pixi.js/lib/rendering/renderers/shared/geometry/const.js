'use strict';

var deprecation = require('../../../../utils/logging/deprecation.js');

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
    deprecation.deprecation(deprecation.v8_0_0, `DRAW_MODES.${prop} is deprecated, use '${DEPRECATED_DRAW_MODES[prop]}' instead`);
    return target[prop];
  }
});

exports.DRAW_MODES = DRAW_MODES;
//# sourceMappingURL=const.js.map
