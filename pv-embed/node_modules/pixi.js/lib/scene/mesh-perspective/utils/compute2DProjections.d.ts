import type { ArrayFixed } from '../../../utils/types';
type Matrix3x3 = ArrayFixed<number, 9>;
/**
 * Compute a 2D projection matrix
 * @param out - The matrix to store the result in
 * @param x1s - The x coordinate of the first source point
 * @param y1s - The y coordinate of the first source point
 * @param x1d - The x coordinate of the first destination point
 * @param y1d - The y coordinate of the first destination point
 * @param x2s - The x coordinate of the second source point
 * @param y2s - The y coordinate of the second source point
 * @param x2d - The x coordinate of the second destination point
 * @param y2d - The y coordinate of the second destination point
 * @param x3s - The x coordinate of the third source point
 * @param y3s - The y coordinate of the third source point
 * @param x3d - The x coordinate of the third destination point
 * @param y3d - The y coordinate of the third destination point
 * @param x4s - The x coordinate of the fourth source point
 * @param y4s - The y coordinate of the fourth source point
 * @param x4d - The x coordinate of the fourth destination point
 * @param y4d - The y coordinate of the fourth destination point
 * @returns - The computed 2D projection matrix
 * @private
 */
export declare function compute2DProjection(out: Matrix3x3, x1s: number, y1s: number, x1d: number, y1d: number, x2s: number, y2s: number, x2d: number, y2d: number, x3s: number, y3s: number, x3d: number, y3d: number, x4s: number, y4s: number, x4d: number, y4d: number): Matrix3x3;
export {};
