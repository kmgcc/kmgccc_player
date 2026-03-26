import EventEmitter from 'eventemitter3';
import { type ColorSource } from '../../../color/Color';
import { Matrix } from '../../../maths/matrix/Matrix';
import { type GCable, type GCData } from '../../../rendering/renderers/shared/GCSystem';
import { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import { Bounds } from '../../container/bounds/Bounds';
import { type GpuGraphicsContext } from './GraphicsContextSystem';
import { GraphicsPath } from './path/GraphicsPath';
import type { PointData } from '../../../maths/point/PointData';
import type { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import type { TextureDestroyOptions, TypeOrBool } from '../../container/destroyTypes';
import type { ConvertedFillStyle, ConvertedStrokeStyle, FillInput, StrokeInput } from './FillTypes';
import type { RoundedPoint } from './path/roundShape';
/**
 * The mode for batching graphics instructions.
 *
 * It can be:
 * - 'auto': Automatically determines whether to batch based on the number of instructions.
 * - 'batch': Forces batching of all instructions.
 * - 'no-batch': Disables batching, processing each instruction individually.
 * @category scene
 * @advanced
 */
export type BatchMode = 'auto' | 'batch' | 'no-batch';
/** @internal */
export interface FillInstruction {
    action: 'fill' | 'cut';
    data: {
        style: ConvertedFillStyle;
        path: GraphicsPath;
        hole?: GraphicsPath;
    };
}
/** @internal */
export interface StrokeInstruction {
    action: 'stroke';
    data: {
        style: ConvertedStrokeStyle;
        path: GraphicsPath;
        hole?: GraphicsPath;
    };
}
/** @internal */
export interface TextureInstruction {
    action: 'texture';
    data: {
        image: Texture;
        dx: number;
        dy: number;
        dw: number;
        dh: number;
        transform: Matrix;
        alpha: number;
        style: number;
    };
}
/** @internal */
export type GraphicsInstructions = FillInstruction | StrokeInstruction | TextureInstruction;
/**
 * The GraphicsContext class allows for the creation of lightweight objects that contain instructions for drawing shapes and paths.
 * It is used internally by the Graphics class to draw shapes and paths, and can be used directly and shared between Graphics objects,
 *
 * This sharing of a `GraphicsContext` means that the intensive task of converting graphics instructions into GPU-ready geometry is done once, and the results are reused,
 * much like sprites reusing textures.
 * @category scene
 * @standard
 */
export declare class GraphicsContext extends EventEmitter<{
    update: GraphicsContext;
    destroy: GraphicsContext;
    unload: GraphicsContext;
}> implements GCable {
    /** @internal */
    _gpuData: Record<number | string, GpuGraphicsContext>;
    /** @internal */
    _gcData?: GCData;
    /** If set to true, the resource will be garbage collected automatically when it is not used. */
    autoGarbageCollect: boolean;
    /** @internal */
    _gcLastUsed: number;
    /** The default fill style to use when none is provided. */
    static defaultFillStyle: ConvertedFillStyle;
    /** The default stroke style to use when none is provided. */
    static defaultStrokeStyle: ConvertedStrokeStyle;
    /**
     * unique id for this graphics context
     * @internal
     */
    readonly uid: number;
    /**
     * Indicates whether content is updated and have to be re-rendered.
     * @internal
     */
    dirty: boolean;
    /** The batch mode for this graphics context. It can be 'auto', 'batch', or 'no-batch'. */
    batchMode: BatchMode;
    /** @internal */
    instructions: GraphicsInstructions[];
    /**
     * Custom shader to apply to the graphics when rendering.
     * @advanced
     */
    customShader?: Shader;
    /** Whether the graphics context has been destroyed. */
    destroyed: boolean;
    private _activePath;
    private _transform;
    private _fillStyle;
    private _strokeStyle;
    private _stateStack;
    private _tick;
    private _bounds;
    private _boundsDirty;
    /**
     * Creates a new GraphicsContext object that is a clone of this instance, copying all properties,
     * including the current drawing state, transformations, styles, and instructions.
     * @returns A new GraphicsContext instance with the same properties and state as this one.
     */
    clone(): GraphicsContext;
    /**
     * The current fill style of the graphics context. This can be a color, gradient, pattern, or a more complex style defined by a FillStyle object.
     */
    get fillStyle(): ConvertedFillStyle;
    set fillStyle(value: FillInput);
    /**
     * The current stroke style of the graphics context. Similar to fill styles, stroke styles can encompass colors, gradients, patterns, or more detailed configurations via a StrokeStyle object.
     */
    get strokeStyle(): ConvertedStrokeStyle;
    set strokeStyle(value: FillInput);
    /**
     * Sets the current fill style of the graphics context. The fill style can be a color, gradient,
     * pattern, or a more complex style defined by a FillStyle object.
     * @param style - The fill style to apply. This can be a simple color, a gradient or pattern object,
     *                or a FillStyle or ConvertedFillStyle object.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    setFillStyle(style: FillInput): this;
    /**
     * Sets the current stroke style of the graphics context. Similar to fill styles, stroke styles can
     * encompass colors, gradients, patterns, or more detailed configurations via a StrokeStyle object.
     * @param style - The stroke style to apply. Can be defined as a color, a gradient or pattern,
     *                or a StrokeStyle or ConvertedStrokeStyle object.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    setStrokeStyle(style: StrokeInput): this;
    /**
     * Adds a texture to the graphics context. This method supports multiple overloads for specifying the texture.
     * If only a texture is provided, it uses the texture's width and height for drawing.
     * @param texture - The Texture object to use.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    texture(texture: Texture): this;
    /**
     * Adds a texture to the graphics context. This method supports multiple overloads for specifying the texture,
     * tint, and dimensions. If only a texture is provided, it uses the texture's width and height for drawing.
     * Additional parameters allow for specifying a tint color, and custom dimensions for the texture drawing area.
     * @param texture - The Texture object to use.
     * @param tint - (Optional) A ColorSource to tint the texture. If not provided, defaults to white (0xFFFFFF).
     * @param dx - (Optional) The x-coordinate in the destination canvas at which to place the top-left corner of
     * the source image.
     * @param dy - (Optional) The y-coordinate in the destination canvas at which to place the top-left corner of
     * the source image.
     * @param dw - (Optional) The width of the rectangle within the source image to draw onto the destination canvas.
     * If not provided, uses the texture's frame width.
     * @param dh - (Optional) The height of the rectangle within the source image to draw onto the destination canvas.
     * If not provided, uses the texture's frame height.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    texture(texture: Texture, tint?: ColorSource, dx?: number, dy?: number, dw?: number, dh?: number): this;
    /**
     * Resets the current path. Any previous path and its commands are discarded and a new path is
     * started. This is typically called before beginning a new shape or series of drawing commands.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    beginPath(): this;
    /**
     * Fills the current or given path with the current fill style. This method can optionally take
     * a color and alpha for a simple fill, or a more complex FillInput object for advanced fills.
     * @param style - (Optional) The style to fill the path with. Can be a color, gradient, pattern, or a complex style object. If omitted, uses the current fill style.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    fill(style?: FillInput): this;
    /** @deprecated 8.0.0 */
    fill(color: ColorSource, alpha: number): this;
    private _initNextPathLocation;
    /**
     * Strokes the current path with the current stroke style. This method can take an optional
     * FillInput parameter to define the stroke's appearance, including its color, width, and other properties.
     * @param style - (Optional) The stroke style to apply. Can be defined as a simple color or a more complex style object. If omitted, uses the current stroke style.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    stroke(style?: StrokeInput): this;
    /**
     * Applies a cutout to the last drawn shape. This is used to create holes or complex shapes by
     * subtracting a path from the previously drawn path. If a hole is not completely in a shape, it will
     * fail to cut correctly!
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    cut(): this;
    /**
     * Adds an arc to the current path, which is centered at (x, y) with the specified radius,
     * starting and ending angles, and direction.
     * @param x - The x-coordinate of the arc's center.
     * @param y - The y-coordinate of the arc's center.
     * @param radius - The arc's radius.
     * @param startAngle - The starting angle, in radians.
     * @param endAngle - The ending angle, in radians.
     * @param counterclockwise - (Optional) Specifies whether the arc is drawn counterclockwise (true) or clockwise (false). Defaults to false.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    arc(x: number, y: number, radius: number, startAngle: number, endAngle: number, counterclockwise?: boolean): this;
    /**
     * Adds an arc to the current path with the given control points and radius, connected to the previous point
     * by a straight line if necessary.
     * @param x1 - The x-coordinate of the first control point.
     * @param y1 - The y-coordinate of the first control point.
     * @param x2 - The x-coordinate of the second control point.
     * @param y2 - The y-coordinate of the second control point.
     * @param radius - The arc's radius.
     * @returns The instance of the current GraphicsContext for method chaining.
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
     * @returns The instance of the current object for chaining.
     */
    ellipse(x: number, y: number, radiusX: number, radiusY: number): this;
    /**
     * Draws a circle shape. This method adds a new circle path to the current drawing.
     * @param x - The x-coordinate of the center of the circle.
     * @param y - The y-coordinate of the center of the circle.
     * @param radius - The radius of the circle.
     * @returns The instance of the current object for chaining.
     */
    circle(x: number, y: number, radius: number): this;
    /**
     * Adds another `GraphicsPath` to this path, optionally applying a transformation.
     * @param path - The `GraphicsPath` to add.
     * @returns The instance of the current object for chaining.
     */
    path(path: GraphicsPath): this;
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
     * Draws a rectangle shape. This method adds a new rectangle path to the current drawing.
     * @param x - The x-coordinate of the top-left corner of the rectangle.
     * @param y - The y-coordinate of the top-left corner of the rectangle.
     * @param w - The width of the rectangle.
     * @param h - The height of the rectangle.
     * @returns The instance of the current object for chaining.
     */
    rect(x: number, y: number, w: number, h: number): this;
    /**
     * Draws a rectangle with rounded corners.
     * The corner radius can be specified to determine how rounded the corners should be.
     * An optional transformation can be applied, which allows for rotation, scaling, and translation of the rectangle.
     * @param x - The x-coordinate of the top-left corner of the rectangle.
     * @param y - The y-coordinate of the top-left corner of the rectangle.
     * @param w - The width of the rectangle.
     * @param h - The height of the rectangle.
     * @param radius - The radius of the rectangle's corners. If not specified, corners will be sharp.
     * @returns The instance of the current object for chaining.
     */
    roundRect(x: number, y: number, w: number, h: number, radius?: number): this;
    /**
     * Draws a polygon shape by specifying a sequence of points. This method allows for the creation of complex polygons,
     * which can be both open and closed. An optional transformation can be applied, enabling the polygon to be scaled,
     * rotated, or translated as needed.
     * @param points - An array of numbers, or an array of PointData objects eg [{x,y}, {x,y}, {x,y}]
     * representing the x and y coordinates, of the polygon's vertices, in sequence.
     * @param close - A boolean indicating whether to close the polygon path. True by default.
     */
    poly(points: number[] | PointData[], close?: boolean): this;
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
     * @returns The instance of the current object for chaining further drawing commands.
     */
    star(x: number, y: number, points: number, radius: number, innerRadius?: number, rotation?: number): this;
    /**
     * Parses and renders an SVG string into the graphics context. This allows for complex shapes and paths
     * defined in SVG format to be drawn within the graphics context.
     * @param svg - The SVG string to be parsed and rendered.
     */
    svg(svg: string): this;
    /**
     * Restores the most recently saved graphics state by popping the top of the graphics state stack.
     * This includes transformations, fill styles, and stroke styles.
     */
    restore(): this;
    /** Saves the current graphics state, including transformations, fill styles, and stroke styles, onto a stack. */
    save(): this;
    /**
     * Returns the current transformation matrix of the graphics context.
     * @returns The current transformation matrix.
     */
    getTransform(): Matrix;
    /**
     * Resets the current transformation matrix to the identity matrix, effectively removing any transformations (rotation, scaling, translation) previously applied.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    resetTransform(): this;
    /**
     * Applies a rotation transformation to the graphics context around the current origin.
     * @param angle - The angle of rotation in radians.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    rotate(angle: number): this;
    /**
     * Applies a scaling transformation to the graphics context, scaling drawings by x horizontally and by y vertically.
     * @param x - The scale factor in the horizontal direction.
     * @param y - (Optional) The scale factor in the vertical direction. If not specified, the x value is used for both directions.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    scale(x: number, y?: number): this;
    /**
     * Sets the current transformation matrix of the graphics context to the specified matrix or values.
     * This replaces the current transformation matrix.
     * @param transform - The matrix to set as the current transformation matrix.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    setTransform(transform: Matrix): this;
    /**
     * Sets the current transformation matrix of the graphics context to the specified matrix or values.
     * This replaces the current transformation matrix.
     * @param a - The value for the a property of the matrix, or a Matrix object to use directly.
     * @param b - The value for the b property of the matrix.
     * @param c - The value for the c property of the matrix.
     * @param d - The value for the d property of the matrix.
     * @param dx - The value for the tx (translate x) property of the matrix.
     * @param dy - The value for the ty (translate y) property of the matrix.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    setTransform(a: number, b: number, c: number, d: number, dx: number, dy: number): this;
    /**
     * Applies the specified transformation matrix to the current graphics context by multiplying
     * the current matrix with the specified matrix.
     * @param transform - The matrix to apply to the current transformation.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    transform(transform: Matrix): this;
    /**
     * Applies the specified transformation matrix to the current graphics context by multiplying
     * the current matrix with the specified matrix.
     * @param a - The value for the a property of the matrix, or a Matrix object to use directly.
     * @param b - The value for the b property of the matrix.
     * @param c - The value for the c property of the matrix.
     * @param d - The value for the d property of the matrix.
     * @param dx - The value for the tx (translate x) property of the matrix.
     * @param dy - The value for the ty (translate y) property of the matrix.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    transform(a: number, b: number, c: number, d: number, dx: number, dy: number): this;
    /**
     * Applies a translation transformation to the graphics context, moving the origin by the specified amounts.
     * @param x - The amount to translate in the horizontal direction.
     * @param y - (Optional) The amount to translate in the vertical direction. If not specified, the x value is used for both directions.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    translate(x: number, y?: number): this;
    /**
     * Clears all drawing commands from the graphics context, effectively resetting it. This includes clearing the path,
     * and optionally resetting transformations to the identity matrix.
     * @returns The instance of the current GraphicsContext for method chaining.
     */
    clear(): this;
    protected onUpdate(): void;
    /** The bounds of the graphic shape. */
    get bounds(): Bounds;
    /**
     * Check to see if a point is contained within this geometry.
     * @param point - Point to check if it's contained.
     * @returns {boolean} `true` if the point is contained within geometry.
     */
    containsPoint(point: PointData): boolean;
    /** Unloads the GPU data from the graphics context. */
    unload(): void;
    /**
     * Destroys the GraphicsData object.
     * @param options - Options parameter. A boolean will act as if all options
     *  have been set to that value
     * @example
     * context.destroy();
     * context.destroy(true);
     * context.destroy({ texture: true, textureSource: true });
     */
    destroy(options?: TypeOrBool<TextureDestroyOptions>): void;
}
