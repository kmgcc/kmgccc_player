import { Matrix } from '../../../../maths/matrix/Matrix';
import { Bounds } from '../Bounds';
import type { PoolItem } from '../../../../utils/pool/Pool';
type MatrixPoolItem = Matrix & PoolItem;
type BoundsPoolItem = Bounds & PoolItem;
/** @internal */
export declare const matrixPool: import("../../../../utils/pool/Pool").Pool<MatrixPoolItem, any>;
/** @internal */
export declare const boundsPool: import("../../../../utils/pool/Pool").Pool<BoundsPoolItem, any>;
export {};
