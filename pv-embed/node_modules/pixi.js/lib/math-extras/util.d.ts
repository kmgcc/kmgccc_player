import { Point } from '../maths/point/Point';
import './pointExtras';
import './rectangleExtras';
import type { PointData } from '../maths/point/PointData';
/**
 * The idea of a relative epsilon comparison is to find the difference between the two numbers,
 * and see if it is less than a given epsilon.
 * A good epsilon would be the N% of the largest of the two values or `Math.EPSILON`.
 *
 * _Note: Only available with **pixi.js/math-extras**._
 * @param {number} a - First floating number to compare.
 * @param {number} b - Second floating number to compare.
 * @param {number} epsilon - The epsilon to compare to.
 * The larger the epsilon, the easier for the numbers to be considered equals.
 * @returns {boolean} Returns `true` if the difference between the values is less than the given epsilon;
 * otherwise `false`.
 * @category maths
 * @advanced
 */
export declare function floatEqual(a: number, b: number, epsilon?: number): boolean;
/**
 * Computes the point where non-coincident and non-parallel Lines intersect.
 * Coincident or parallel lines return a `NaN` point `{x: NaN, y: NaN}`.
 * The intersection point may land outside the extents of the lines.
 *
 * _Note: Only available with **pixi.js/math-extras**._
 * @param aStart - First point of the first line.
 * @param aEnd - Second point of the first line.
 * @param bStart - First point of the second line.
 * @param bEnd - Second point of the second line.
 * @param {PointData} outPoint - A Point-like object in which to store the value,
 * optional (otherwise will create a new Point).
 * @returns {PointData} The point where the lines intersect or a `NaN` Point.
 * @category maths
 * @advanced
 */
export declare function lineIntersection<T extends PointData = Point>(aStart: PointData, aEnd: PointData, bStart: PointData, bEnd: PointData, outPoint?: T): T;
/**
 * Computes the point where non-coincident and non-parallel segments intersect.
 * Coincident, parallel or non-intersecting segments return a `NaN` point `{x: NaN, y: NaN}`.
 * The intersection point must land inside the extents of the segments or return a `NaN` Point.
 *
 * _Note: Only available with **pixi.js/math-extras**._
 * @param aStart - Starting point of the first segment.
 * @param aEnd - Ending point of the first segment.
 * @param bStart - Starting point of the second segment.
 * @param bEnd - Ending point of the second segment.
 * @param {PointData} outPoint - A Point-like object in which to store the value,
 * optional (otherwise will create a new Point).
 * @returns {PointData} The point where the segments intersect or a `NaN` Point.
 * @category maths
 * @advanced
 */
export declare function segmentIntersection<T extends PointData = Point>(aStart: PointData, aEnd: PointData, bStart: PointData, bEnd: PointData, outPoint?: T): T;
