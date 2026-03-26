'use strict';

"use strict";
const convertToList = (input, transform, forceTransform = false) => {
  if (!Array.isArray(input)) {
    input = [input];
  }
  if (!transform) {
    return input;
  }
  return input.map((item) => {
    if (typeof item === "string" || forceTransform) {
      return transform(item);
    }
    return item;
  });
};

exports.convertToList = convertToList;
//# sourceMappingURL=convertToList.js.map
