import type { PointData } from '../../../../maths/point/PointData';
import type { ShapePath } from './ShapePath';
/**
 * Typed and cleaned up version of:
 * https://stackoverflow.com/questions/44855794/html5-canvas-triangle-with-rounded-corners/44856925#44856925
 * @param g - Graphics to be drawn on.
 * @param points - Corners of the shape to draw. Minimum length is 3.
 * @param radius - Corners default radius.
 * @ignore
 */
export declare function roundedShapeArc(g: ShapePath, points: RoundedPoint[], radius: number): void;
/**
 * Data structure for points with optional radius.
 * @category scene
 * @standard
 */
export type RoundedPoint = PointData & {
    radius?: number;
};
/**
 * Typed and cleaned up version of:
 * https://stackoverflow.com/questions/44855794/html5-canvas-triangle-with-rounded-corners/56214413#56214413
 * @param g - Graphics to be drawn on.
 * @param points - Corners of the shape to draw. Minimum length is 3.
 * @param radius - Corners default radius.
 * @ignore
 */
export declare function roundedShapeQuadraticCurve(g: ShapePath, points: RoundedPoint[], radius: number, smoothness?: number): void;
