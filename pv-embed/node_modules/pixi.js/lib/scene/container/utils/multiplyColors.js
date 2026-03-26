'use strict';

var multiplyHexColors = require('./multiplyHexColors.js');

"use strict";
const WHITE_BGR = 16777215;
function multiplyColors(localBGRColor, parentBGRColor) {
  if (localBGRColor === WHITE_BGR) {
    return parentBGRColor;
  }
  if (parentBGRColor === WHITE_BGR) {
    return localBGRColor;
  }
  return multiplyHexColors.multiplyHexColors(localBGRColor, parentBGRColor);
}

exports.multiplyColors = multiplyColors;
//# sourceMappingURL=multiplyColors.js.map
