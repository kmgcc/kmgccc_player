'use strict';

"use strict";
let warnCount = 0;
const maxWarnings = 500;
function warn(...args) {
  if (warnCount === maxWarnings) return;
  warnCount++;
  if (warnCount === maxWarnings) {
    console.warn("PixiJS Warning: too many warnings, no more warnings will be reported to the console by PixiJS.");
  } else {
    console.warn("PixiJS Warning: ", ...args);
  }
}

exports.warn = warn;
//# sourceMappingURL=warn.js.map
