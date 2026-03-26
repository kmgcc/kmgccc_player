import { Point } from '../../../maths/point/Point.mjs';
import { matrixPool } from '../bounds/utils/matrixAndBoundsPool.mjs';

"use strict";
const toLocalGlobalMixin = {
  getGlobalPosition(point = new Point(), skipUpdate = false) {
    if (this.parent) {
      this.parent.toGlobal(this._position, point, skipUpdate);
    } else {
      point.x = this._position.x;
      point.y = this._position.y;
    }
    return point;
  },
  toGlobal(position, point, skipUpdate = false) {
    const globalMatrix = this.getGlobalTransform(matrixPool.get(), skipUpdate);
    point = globalMatrix.apply(position, point);
    matrixPool.return(globalMatrix);
    return point;
  },
  toLocal(position, from, point, skipUpdate) {
    if (from) {
      position = from.toGlobal(position, point, skipUpdate);
    }
    const globalMatrix = this.getGlobalTransform(matrixPool.get(), skipUpdate);
    point = globalMatrix.applyInverse(position, point);
    matrixPool.return(globalMatrix);
    return point;
  }
};

export { toLocalGlobalMixin };
//# sourceMappingURL=toLocalGlobalMixin.mjs.map
