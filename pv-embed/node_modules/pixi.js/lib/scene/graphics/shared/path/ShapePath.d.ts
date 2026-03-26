import { Bounds } from '../../../container/bounds/Bounds';
import type { Matrix } from '../../../../maths/matrix/Matrix';
import type { PointData } from '../../../../maths/point/PointData';
import type { ShapePrimitive } from '../../../../maths/shapes/ShapePrimitive';
import type { GraphicsPath } from './GraphicsPath';
import type { RoundedPoint } from './roundShape';
/**
 * A type representing a shape primitive with optional transformation and holes.
 * @category scene
 * @advanced
 */
export type ShapePrimitiveWithHoles = {
    shape: ShapePrimitive;
    transform?: Matrix;
    holes?: ShapePrimitiveWithHoles[];
};
/**
 * The `ShapePath` class acts as a bridge between high-level drawing commands
 * and the lower-level `GraphicsContext` rendering engine.
 * It translates drawing commands, such as those for creating lines, arcs, ellipses, rectangles, and complex polygons, into a
 * format that can be efficiently processed by a `GraphicsContext`. This includes handling path starts,
 * ends, and transformations for shapes.
 *
 * It is used internally by `GraphicsPath` to build up the path.
 * @category scene
 * @advanced
 */
export declare class ShapePath {
    /** The list of shape primitives that make up the path. */
    shapePrimitives: ShapePrimitiveWithHoles[];
    private _currentPoly;
    private readonly _graphicsPath2D;
    private readonly _bounds;
    readonly signed: boolean;
    constructor(graphicsPath2D: GraphicsPath);
    /**
     * Sets the starting point for a new sub-path. Any subsequent drawing commands are considered part of this path.
     * @param x - The x-coordinate for the starting point.
     * @param y - The y-coordinate for the starting point.
     * @returns The instance of the current object for chaining.
     */
    moveTo(x: number, y: number): this;
    /**
     * Connects the current point to a new point with a straight line. This method updates the current path.
     * @param x - The x-coordinate of the new point to connect to.
     * @param y - The y-coordinate of the new point to connect to.
     * @returns The instance of the current object for chaining.
     */
    lineTo(x: number, y: number): this;
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
    arc(x: number, y: number, radius: number, startAngle: number, endAngle: number, counterclockwise: boolean): this;
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
     * Adds a quadratic curve to the path. It requires two points: the control point and the end point.
     * The starting point is the last point in the current path.
     * @param cp1x - The x-coordinate of the control point.
     * @param cp1y - The y-coordinate of the control point.
     * @param x - The x-coordinate of the end point.
     * @param y - The y-coordinate of the end point.
     * @param smoothing - Optional parameter to adjust the smoothness of the curve.
     * @returns The instance of the current object for chaining.
     */
    quadraticCurveTo(cp1x: number, cp1y: number, x: number, y: number, smoothing?: number): this;
    /**
     * Closes the current path by drawing a straight line back to the start.
     * If the shape is already closed or there are no points in the path, this method does nothing.
     * @returns The instance of the current object for chaining.
     */
    closePath(): this;
    /**
     * Adds another path to the current path. This method allows for the combination of multiple paths into one.
     * @param path - The `GraphicsPath` object representing the path to add.
     * @param transform - An optional `Matrix` object to apply a transformation to the path before adding it.
     * @returns The instance of the current object for chaining.
     */
    addPath(path: GraphicsPath, transform?: Matrix): this;
    /**
     * Finalizes the drawing of the current path. Optionally, it can close the path.
     * @param closePath - A boolean indicating whether to close the path after finishing. False by default.
     */
    finish(closePath?: boolean): void;
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
     * Draws a polygon shape. This method allows for the creation of complex polygons by specifying a sequence of points.
     * @param points - An array of numbers, or or an array of PointData objects eg [{x,y}, {x,y}, {x,y}]
     * representing the x and y coordinates of the polygon's vertices, in sequence.
     * @param close - A boolean indicating whether to close the polygon path. True by default.
     * @param transform - An optional `Matrix` object to apply a transformation to the polygon.
     * @returns The instance of the current object for chaining.
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
     * @param smoothness - Optional parameter to adjust the smoothness of the rounding.
     * @returns The instance of the current object for chaining.
     */
    roundPoly(x: number, y: number, radius: number, sides: number, corner: number, rotation?: number, smoothness?: number): this;
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
     * Draws an ellipse at the specified location and with the given x and y radii.
     * An optional transformation can be applied, allowing for rotation, scaling, and translation.
     * @param x - The x-coordinate of the center of the ellipse.
     * @param y - The y-coordinate of the center of the ellipse.
     * @param radiusX - The horizontal radius of the ellipse.
     * @param radiusY - The vertical radius of the ellipse.
     * @param transform - An optional `Matrix` object to apply a transformation to the ellipse. This can include rotations.
     * @returns The instance of the current object for chaining.
     */
    ellipse(x: number, y: number, radiusX: number, radiusY: number, transform?: Matrix): this;
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
     * Draws a given shape on the canvas.
     * This is a generic method that can draw any type of shape specified by the `ShapePrimitive` parameter.
     * An optional transformation matrix can be applied to the shape, allowing for complex transformations.
     * @param shape - The shape to draw, defined as a `ShapePrimitive` object.
     * @param matrix - An optional `Matrix` for transforming the shape. This can include rotations,
     * scaling, and translations.
     * @returns The instance of the current object for chaining.
     */
    drawShape(shape: ShapePrimitive, matrix?: Matrix): this;
    /**
     * Starts a new polygon path from the specified starting point.
     * This method initializes a new polygon or ends the current one if it exists.
     * @param x - The x-coordinate of the starting point of the new polygon.
     * @param y - The y-coordinate of the starting point of the new polygon.
     * @returns The instance of the current object for chaining.
     */
    startPoly(x: number, y: number): this;
    /**
     * Ends the current polygon path. If `closePath` is set to true,
     * the path is closed by connecting the last point to the first one.
     * This method finalizes the current polygon and prepares it for drawing or adding to the shape primitives.
     * @param closePath - A boolean indicating whether to close the polygon by connecting the last point
     *  back to the starting point. False by default.
     * @returns The instance of the current object for chaining.
     */
    endPoly(closePath?: boolean): this;
    private _ensurePoly;
    /** Builds the path. */
    buildPath(): void;
    /** Gets the bounds of the path. */
    get bounds(): Bounds;
}
