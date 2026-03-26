'use strict';

"use strict";
const idCounts = /* @__PURE__ */ Object.create(null);
const idHash = /* @__PURE__ */ Object.create(null);
function createIdFromString(value, groupId) {
  let id = idHash[value];
  if (id === void 0) {
    if (idCounts[groupId] === void 0) {
      idCounts[groupId] = 1;
    }
    idHash[value] = id = idCounts[groupId]++;
  }
  return id;
}

exports.createIdFromString = createIdFromString;
//# sourceMappingURL=createIdFromString.js.map
