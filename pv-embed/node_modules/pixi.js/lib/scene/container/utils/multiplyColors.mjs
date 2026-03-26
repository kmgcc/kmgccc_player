import { multiplyHexColors } from './multiplyHexColors.mjs';

"use strict";
const WHITE_BGR = 16777215;
function multiplyColors(localBGRColor, parentBGRColor) {
  if (localBGRColor === WHITE_BGR) {
    return parentBGRColor;
  }
  if (parentBGRColor === WHITE_BGR) {
    return localBGRColor;
  }
  return multiplyHexColors(localBGRColor, parentBGRColor);
}

export { multiplyColors };
//# sourceMappingURL=multiplyColors.mjs.map
