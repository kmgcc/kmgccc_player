import { Point } from '../../../../maths/point/Point';
import { ShapePath } from './ShapePath';
import type { Matrix } from '../../../../maths/matrix/Matrix';
import type { PointData } from '../../../../maths/point/PointData';
import type { Bounds } from '../../../container/bounds/Bounds';
import type { RoundedPoint } from './roundShape';
/**
 * Represents a single drawing instruction in a `GraphicsPath`.
 * Each instruction consists of an action type and associated data.
 * @category scene
 * @advanced
 */
export interface PathInstruction {
    action: 'moveTo' | 'lineTo' | 'quadraticCurveTo' | 'bezierCurveTo' | 'arc' | 'closePath' | 'addPath' | 'arcTo' | 'ellipse' | 'rect' | 'roundRect' | 'arcToSvg' | 'poly' | 'circle' | 'regularPoly' | 'roundPoly' | 'roundShape' | 'filletRect' | 'chamferRect';
    data: any[];
}
/**
 * The `GraphicsPath` class is designed to represent a graphical path consisting of multiple drawing instructions.
 * This class serves as a collection of drawing commands that can be executed to render shapes and paths on a canvas or
 * similar graphical context. It supports high-level drawing operations like lines, arcs, curves, and more, enabling
 * complex graphic constructions with relative ease.
 * @category scene
 * @advanced
 */
export declare class GraphicsPath {
    instructions: PathInstruction[];
    /** unique id for this graphics path */
    readonly uid: number;
    private _dirty;
    private _shapePath;
    /**
     * Controls whether shapes in this path should be checked for holes using the non-zero fill rule.
     * When true, any closed shape that is fully contained within another shape will become
     * a hole in that shape during filling operations.
     *
     * This follows SVG's non-zero fill rule where:
     * 1. Shapes are analyzed to find containment relationships
     * 2. If Shape B is fully contained within Shape A, Shape B becomes a hole in Shape A
     * 3. Multiple nested holes are supported
     *
     * Mainly used internally by the SVG parser to correctly handle holes in complex paths.
     * When false, all shapes are filled independently without checking for holes.
     */
    checkForHoles: boolean;
    /**
     * Provides access to the internal shape path, ensuring it is up-to-date with the current instructions.
     * @returns The `ShapePath` instance associated with this `GraphicsPath`.
     */
    get shapePath(): ShapePath;
    /**
     * Creates a `GraphicsPath` instance optionally from an SVG path string or an array of `PathInstruction`.
     * @param instructions - An SVG path string or an array of `PathInstruction` objects.
     * @param signed
     */
    constructor(instructions?: string | PathInstruction[], signed?: boolean);
    /**
     * Adds another `GraphicsPath` to this path, optionally applying a transformation.
     * @param path - The `GraphicsPath` to add.
     * @param transform - An optional transformation to apply to the added path.
     * @returns The instance of the current object for chaining.
     */
    addPath(path: GraphicsPath, transform?: Matrix): this;
    /**
     * Adds an arc to the path. The arc is centered at (x, y)
     *  position with radius `radius` starting at `startAngle` and ending at `endAngle`.
     * @param x - The x-coordinate of the arc's center.
     * @param y - The y-coordinate of the arc's center.
     * @param radius - The radius of the arc.
     * @param startAngle - The starting angle of the arc, in radians.
     * @param endAngle - The ending angle of the arc, in radians.
     * @param counterclockwise - Specifies whether the arc should be drawn in the anticlockwise direction. False by default.
     * @returns The instance of the current object for chaining.
     */
    arc(x: number, y: number, radius: number, startAngle: number, endAngle: number, counterclockwise?: boolean): this;
    /**
     * Adds an arc to the path with the arc tangent to the line joining two specified points.
     * The arc radius is specified by `radius`.
     * @param x1 - The x-coordinate of the first point.
     * @param y1 - The y-coordinate of the first point.
     * @param x2 - The x-coordinate of the second point.
     * @param y2 - The y-coordinate of the second point.
     * @param radius - The radius of the arc.
     * @returns The instance of the current object for chaining.
     */
    arcTo(x1: number, y1: number, x2: number, y2: number, radius: number): this;
    /**
     * Adds an SVG-style arc to the path, allowing for elliptical arcs based on the SVG spec.
     * @param rx - The x-radius of the ellipse.
     * @param ry - The y-radius of the ellipse.
     * @param xAxisRotation - The rotation of the ellipse's x-axis relative
     * to the x-axis of the coordinate system, in degrees.
     * @param largeArcFlag - Determines if the arc should be greater than or less than 180 degrees.
     * @param sweepFlag - Determines if the arc should be swept in a positive angle direction.
     * @param x - The x-coordinate of the arc's end point.
     * @param y - The y-coordinate of the arc's end point.
     * @returns The instance of the current object for chaining.
     */
    arcToSvg(rx: number, ry: number, xAxisRotation: number, largeArcFlag: number, sweepFlag: number, x: number, y: number): this;
    /**
     * Adds a cubic Bezier curve to the path.
     * It requires three points: the first two are control points and the third one is the end point.
     * The starting point is the last point in the current path.
     * @param cp1x - The x-coordinate of the first control point.
     * @param cp1y - The y-coordinate of the first control point.
     * @param cp2x - The x-coordinate of the second control point.
     * @param cp2y - The y-coordinate of the second control point.
     * @param x - The x-coordinate of the end point.
     * @param y - The y-coordinate of the end point.
     * @param smoothness - Optional parameter to adjust the smoothness of the curve.
     * @returns The instance of the current object for chaining.
     */
    bezierCurveTo(cp1x: number, cp1y: number, cp2x: number, cp2y: number, x: number, y: number, smoothness?: number): this;
    /**
     * Adds a cubic Bezier curve to the path.
     * It requires two points: the second control point and the end point. The first control point is assumed to be
     * The starting point is the last point in the current path.
     * @param cp2x - The x-coordinate of the second control point.
     * @param cp2y - The y-coordinate of the second control point.
     * @param x - The x-coordinate of the end point.
     * @param y - The y-coordinate of the end point.
     * @param smoothness - Optional parameter to adjust the smoothness of the curve.
     * @returns The instance of the current object for chaining.
     */
    bezierCurveToShort(cp2x: number, cp2y: number, x: number, y: number, smoothness?: number): this;
    /**
     * Closes the current path by drawing a straight line back to the start.
     * If the shape is already closed or there are no points in the path, this method does nothing.
     * @returns The instance of the current object for chaining.
     */
    closePath(): this;
    /**
     * Draws an ellipse at the specified location and with the given x and y radii.
     * An optional transformation can be applied, allowing for rotation, scaling, and translation.
     * @param x - The x-coordinate of the center of the ellipse.
     * @param y - The y-coordinate of the center of the ellipse.
     * @param radiusX - The horizontal radius of the ellipse.
     * @param radiusY - The vertical radius of the ellipse.
     * @param matrix - An optional `Matrix` object to apply a transformation to the ellipse. This can include rotations.
     * @returns The instance of the current object for chaining.
     */
    ellipse(x: number, y: number, radiusX: number, radiusY: number, matrix?: Matrix): this;
    /**
     * Connects the current point to a new point with a straight line. This method updates the current path.
     * @param x - The x-coordinate of the new point to connect to.
     * @param y - The y-coordinate of the new point to connect to.
     * @returns The instance of the current object for chaining.
     */
    lineTo(x: number, y: number): this;
    /**
     * Sets the starting point for a new sub-path. Any subsequent drawing commands are considered part of this path.
     * @param x - The x-coordinate for the starting point.
     * @param y - The y-coordinate for the starting point.
     * @returns The instance of the current object for chaining.
     */
    moveTo(x: number, y: number): this;
    /**
     * Adds a quadratic curve to the path. It requires two points: the control point and the end point.
     * The starting point is the last point in the current path.
     * @param cpx - The x-coordinate of the control point.
     * @param cpy - The y-coordinate of the control point.
     * @param x - The x-coordinate of the end point.
     * @param y - The y-coordinate of the end point.
     * @param smoothness - Optional parameter to adjust the smoothness of the curve.
     * @returns The instance of the current object for chaining.
     */
    quadraticCurveTo(cpx: number, cpy: number, x: number, y: number, smoothness?: number): this;
    /**
     * Adds a quadratic curve to the path. It uses the previous point as the control point.
     * @param x - The x-coordinate of the end point.
     * @param y - The y-coordinate of the end point.
     * @param smoothness - Optional parameter to adjust the smoothness of the curve.
     * @returns The instance of the current object for chaining.
     */
    quadraticCurveToShort(x: number, y: number, smoothness?: number): this;
    /**
     * Draws a rectangle shape. This method adds a new rectangle path to the current drawing.
     * @param x - The x-coordinate of the top-left corner of the rectangle.
     * @param y - The y-coordinate of the top-left corner of the rectangle.
     * @param w - The width of the rectangle.
     * @param h - The height of the rectangle.
     * @param transform - An optional `Matrix` object to apply a transformation to the rectangle.
     * @returns The instance of the current object for chaining.
     */
    rect(x: number, y: number, w: number, h: number, transform?: Matrix): this;
    /**
     * Draws a circle shape. This method adds a new circle path to the current drawing.
     * @param x - The x-coordinate of the center of the circle.
     * @param y - The y-coordinate of the center of the circle.
     * @param radius - The radius of the circle.
     * @param transform - An optional `Matrix` object to apply a transformation to the circle.
     * @returns The instance of the current object for chaining.
     */
    circle(x: number, y: number, radius: number, transform?: Matrix): this;
    /**
     * Draws a rectangle with rounded corners.
     * The corner radius can be specified to determine how rounded the corners should be.
     * An optional transformation can be applied, which allows for rotation, scaling, and translation of the rectangle.
     * @param x - The x-coordinate of the top-left corner of the rectangle.
     * @param y - The y-coordinate of the top-left corner of the rectangle.
     * @param w - The width of the rectangle.
     * @param h - The height of the rectangle.
     * @param radius - The radius of the rectangle's corners. If not specified, corners will be sharp.
     * @param transform - An optional `Matrix` object to apply a transformation to the rectangle.
     * @returns The instance of the current object for chaining.
     */
    roundRect(x: number, y: number, w: number, h: number, radius?: number, transform?: Matrix): this;
    /**
     * Draws a polygon shape by specifying a sequence of points. This method allows for the creation of complex polygons,
     * which can be both open and closed. An optional transformation can be applied, enabling the polygon to be scaled,
     * rotated, or translated as needed.
     * @param points - An array of numbers representing the x and y coordinates of the polygon's vertices, in sequence.
     * @param close - A boolean indicating whether to close the polygon path. True by default.
     * @param transform - An optional `Matrix` object to apply a transformation to the polygon.
     * @returns The instance of the current object for chaining further drawing commands.
     */
    poly(points: number[] | PointData[], close?: boolean, transform?: Matrix): this;
    /**
     * Draws a regular polygon with a specified number of sides. All sides and angles are equal.
     * @param x - The x-coordinate of the center of the polygon.
     * @param y - The y-coordinate of the center of the polygon.
     * @param radius - The radius of the circumscribed circle of the polygon.
     * @param sides - The number of sides of the polygon. Must be 3 or more.
     * @param rotation - The rotation angle of the polygon, in radians. Zero by default.
     * @param transform - An optional `Matrix` object to apply a transformation to the polygon.
     * @returns The instance of the current object for chaining.
     */
    regularPoly(x: number, y: number, radius: number, sides: number, rotation?: number, transform?: Matrix): this;
    /**
     * Draws a polygon with rounded corners.
     * Similar to `regularPoly` but with the ability to round the corners of the polygon.
     * @param x - The x-coordinate of the center of the polygon.
     * @param y - The y-coordinate of the center of the polygon.
     * @param radius - The radius of the circumscribed circle of the polygon.
     * @param sides - The number of sides of the polygon. Must be 3 or more.
     * @param corner - The radius of the rounding of the corners.
     * @param rotation - The rotation angle of the polygon, in radians. Zero by default.
     * @returns The instance of the current object for chaining.
     */
    roundPoly(x: number, y: number, radius: number, sides: number, corner: number, rotation?: number): this;
    /**
     * Draws a shape with rounded corners. This function supports custom radius for each corner of the shape.
     * Optionally, corners can be rounded using a quadratic curve instead of an arc, providing a different aesthetic.
     * @param points - An array of `RoundedPoint` representing the corners of the shape to draw.
     * A minimum of 3 points is required.
     * @param radius - The default radius for the corners.
     * This radius is applied to all corners unless overridden in `points`.
     * @param useQuadratic - If set to true, rounded corners are drawn using a quadraticCurve
     *  method instead of an arc method. Defaults to false.
     * @param smoothness - Specifies the smoothness of the curve when `useQuadratic` is true.
     * Higher values make the curve smoother.
     * @returns The instance of the current object for chaining.
     */
    roundShape(points: RoundedPoint[], radius: number, useQuadratic?: boolean, smoothness?: number): this;
    /**
     * Draw Rectangle with fillet corners. This is much like rounded rectangle
     * however it support negative numbers as well for the corner radius.
     * @param x - Upper left corner of rect
     * @param y - Upper right corner of rect
     * @param width - Width of rect
     * @param height - Height of rect
     * @param fillet - accept negative or positive values
     */
    filletRect(x: number, y: number, width: number, height: number, fillet: number): this;
    /**
     * Draw Rectangle with chamfer corners. These are angled corners.
     * @param x - Upper left corner of rect
     * @param y - Upper right corner of rect
     * @param width - Width of rect
     * @param height - Height of rect
     * @param chamfer - non-zero real number, size of corner cutout
     * @param transform
     */
    chamferRect(x: number, y: number, width: number, height: number, chamfer: number, transform?: Matrix): this;
    /**
     * Draws a star shape centered at a specified location. This method allows for the creation
     *  of stars with a variable number of points, outer radius, optional inner radius, and rotation.
     * The star is drawn as a closed polygon with alternating outer and inner vertices to create the star's points.
     * An optional transformation can be applied to scale, rotate, or translate the star as needed.
     * @param x - The x-coordinate of the center of the star.
     * @param y - The y-coordinate of the center of the star.
     * @param points - The number of points of the star.
     * @param radius - The outer radius of the star (distance from the center to the outer points).
     * @param innerRadius - Optional. The inner radius of the star
     * (distance from the center to the inner points between the outer points).
     * If not provided, defaults to half of the `radius`.
     * @param rotation - Optional. The rotation of the star in radians, where 0 is aligned with the y-axis.
     * Defaults to 0, meaning one point is directly upward.
     * @param transform - An optional `Matrix` object to apply a transformation to the star.
     * This can include rotations, scaling, and translations.
     * @returns The instance of the current object for chaining further drawing commands.
     */
    star(x: number, y: number, points: number, radius: number, innerRadius?: number, rotation?: number, transform?: Matrix): this;
    /**
     * Creates a copy of the current `GraphicsPath` instance. This method supports both shallow and deep cloning.
     * A shallow clone copies the reference of the instructions array, while a deep clone creates a new array and
     * copies each instruction individually, ensuring that modifications to the instructions of the cloned `GraphicsPath`
     * do not affect the original `GraphicsPath` and vice versa.
     * @param deep - A boolean flag indicating whether the clone should be deep.
     * @returns A new `GraphicsPath` instance that is a clone of the current instance.
     */
    clone(deep?: boolean): GraphicsPath;
    clear(): this;
    /**
     * Applies a transformation matrix to all drawing instructions within the `GraphicsPath`.
     * This method enables the modification of the path's geometry according to the provided
     * transformation matrix, which can include translations, rotations, scaling, and skewing.
     *
     * Each drawing instruction in the path is updated to reflect the transformation,
     * ensuring the visual representation of the path is consistent with the applied matrix.
     *
     * Note: The transformation is applied directly to the coordinates and control points of the drawing instructions,
     * not to the path as a whole. This means the transformation's effects are baked into the individual instructions,
     * allowing for fine-grained control over the path's appearance.
     * @param matrix - A `Matrix` object representing the transformation to apply.
     * @returns The instance of the current object for chaining further operations.
     */
    transform(matrix: Matrix): this;
    get bounds(): Bounds;
    /**
     * Retrieves the last point from the current drawing instructions in the `GraphicsPath`.
     * This method is useful for operations that depend on the path's current endpoint,
     * such as connecting subsequent shapes or paths. It supports various drawing instructions,
     * ensuring the last point's position is accurately determined regardless of the path's complexity.
     *
     * If the last instruction is a `closePath`, the method iterates backward through the instructions
     *  until it finds an actionable instruction that defines a point (e.g., `moveTo`, `lineTo`,
     * `quadraticCurveTo`, etc.). For compound paths added via `addPath`, it recursively retrieves
     * the last point from the nested path.
     * @param out - A `Point` object where the last point's coordinates will be stored.
     * This object is modified directly to contain the result.
     * @returns The `Point` object containing the last point's coordinates.
     */
    getLastPoint(out: Point): Point;
}
