import { Matrix } from '../../../../maths/matrix/Matrix.mjs';
import { BigPool } from '../../../../utils/pool/PoolGroup.mjs';
import { Bounds } from '../Bounds.mjs';

"use strict";
const matrixPool = BigPool.getPool(Matrix);
const boundsPool = BigPool.getPool(Bounds);

export { boundsPool, matrixPool };
//# sourceMappingURL=matrixAndBoundsPool.mjs.map
