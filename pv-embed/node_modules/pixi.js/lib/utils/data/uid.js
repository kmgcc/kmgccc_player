'use strict';

"use strict";
const uidCache = {
  default: -1
};
function uid(name = "default") {
  if (uidCache[name] === void 0) {
    uidCache[name] = -1;
  }
  return ++uidCache[name];
}
function resetUids() {
  for (const key in uidCache) {
    delete uidCache[key];
  }
}

exports.resetUids = resetUids;
exports.uid = uid;
//# sourceMappingURL=uid.js.map
