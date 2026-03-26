'use strict';

var Point = require('../../../maths/point/Point.js');
var matrixAndBoundsPool = require('../bounds/utils/matrixAndBoundsPool.js');

"use strict";
const toLocalGlobalMixin = {
  getGlobalPosition(point = new Point.Point(), skipUpdate = false) {
    if (this.parent) {
      this.parent.toGlobal(this._position, point, skipUpdate);
    } else {
      point.x = this._position.x;
      point.y = this._position.y;
    }
    return point;
  },
  toGlobal(position, point, skipUpdate = false) {
    const globalMatrix = this.getGlobalTransform(matrixAndBoundsPool.matrixPool.get(), skipUpdate);
    point = globalMatrix.apply(position, point);
    matrixAndBoundsPool.matrixPool.return(globalMatrix);
    return point;
  },
  toLocal(position, from, point, skipUpdate) {
    if (from) {
      position = from.toGlobal(position, point, skipUpdate);
    }
    const globalMatrix = this.getGlobalTransform(matrixAndBoundsPool.matrixPool.get(), skipUpdate);
    point = globalMatrix.applyInverse(position, point);
    matrixAndBoundsPool.matrixPool.return(globalMatrix);
    return point;
  }
};

exports.toLocalGlobalMixin = toLocalGlobalMixin;
//# sourceMappingURL=toLocalGlobalMixin.js.map
