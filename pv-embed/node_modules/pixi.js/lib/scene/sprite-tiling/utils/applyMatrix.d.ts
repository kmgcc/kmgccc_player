import type { Matrix } from '../../../maths/matrix/Matrix';
import type { TypedArray } from '../../../rendering/renderers/shared/buffer/Buffer';
/**
 * @param array
 * @param stride
 * @param offset
 * @param matrix
 * @internal
 */
export declare function applyMatrix(array: TypedArray, stride: number, offset: number, matrix: Matrix): void;
