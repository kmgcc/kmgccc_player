'use strict';

var Matrix = require('../../../../maths/matrix/Matrix.js');
var PoolGroup = require('../../../../utils/pool/PoolGroup.js');
var Bounds = require('../Bounds.js');

"use strict";
const matrixPool = PoolGroup.BigPool.getPool(Matrix.Matrix);
const boundsPool = PoolGroup.BigPool.getPool(Bounds.Bounds);

exports.boundsPool = boundsPool;
exports.matrixPool = matrixPool;
//# sourceMappingURL=matrixAndBoundsPool.js.map
