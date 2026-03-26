import { Rectangle } from './Rectangle';
import type { SHAPE_PRIMITIVE } from '../misc/const';
import type { ShapePrimitive } from './ShapePrimitive';
/**
 * A class to define a shape of a triangle via user defined coordinates.
 *
 * Used for creating triangular shapes and hit areas with three points (x,y), (x2,y2), (x3,y3).
 * Points are stored in counter-clockwise order.
 * @example
 * ```ts
 * // Basic triangle creation
 * const triangle = new Triangle(0, 0, 100, 0, 50, 50);
 * // Use as hit area
 * container.hitArea = new Triangle(0, 0, 100, 0, 50, 100);
 * // Check point containment
 * const isInside = triangle.contains(mouseX, mouseY);
 * // Get bounding box
 * const bounds = triangle.getBounds();
 * ```
 * @see {@link Rectangle} For rectangular shapes
 * @see {@link Circle} For circular shapes
 * @see {@link Polygon} For complex shapes
 * @category maths
 * @standard
 */
export declare class Triangle implements ShapePrimitive {
    /**
     * The type of the object, mainly used to avoid `instanceof` checks
     * @example
     * ```ts
     * // Check shape type
     * const shape = new Triangle(0, 0, 100, 0, 50, 100);
     * console.log(shape.type); // 'triangle'
     *
     * // Use in type guards
     * if (shape.type === 'triangle') {
     *     console.log(shape.x2, shape.y2);
     * }
     * ```
     * @readonly
     * @default 'triangle'
     * @see {@link SHAPE_PRIMITIVE} For all shape types
     */
    readonly type: SHAPE_PRIMITIVE;
    /**
     * The X coordinate of the first point of the triangle.
     * @example
     * ```ts
     * // Set first point x position
     * const triangle = new Triangle();
     * triangle.x = 100;
     * ```
     * @default 0
     */
    x: number;
    /**
     * The Y coordinate of the first point of the triangle.
     * @example
     * ```ts
     * // Set first point y position
     * const triangle = new Triangle();
     * triangle.y = 100;
     * ```
     * @default 0
     */
    y: number;
    /**
     * The X coordinate of the second point of the triangle.
     * @example
     * ```ts
     * // Create horizontal line for second point
     * const triangle = new Triangle(0, 0);
     * triangle.x2 = triangle.x + 100; // 100 units to the right
     * ```
     * @default 0
     */
    x2: number;
    /**
     * The Y coordinate of the second point of the triangle.
     * @example
     * ```ts
     * // Create vertical line for second point
     * const triangle = new Triangle(0, 0);
     * triangle.y2 = triangle.y + 100; // 100 units down
     * ```
     * @default 0
     */
    y2: number;
    /**
     * The X coordinate of the third point of the triangle.
     * @example
     * ```ts
     * // Create equilateral triangle
     * const triangle = new Triangle(0, 0, 100, 0);
     * triangle.x3 = 50;  // Middle point x
     * triangle.y3 = 86.6; // Height using sin(60°)
     * ```
     * @default 0
     */
    x3: number;
    /**
     * The Y coordinate of the third point of the triangle.
     * @example
     * ```ts
     * // Create right triangle
     * const triangle = new Triangle(0, 0, 100, 0);
     * triangle.x3 = 0;   // Align with first point
     * triangle.y3 = 100; // 100 units down
     * ```
     * @default 0
     */
    y3: number;
    /**
     * @param x - The X coord of the first point.
     * @param y - The Y coord of the first point.
     * @param x2 - The X coord of the second point.
     * @param y2 - The Y coord of the second point.
     * @param x3 - The X coord of the third point.
     * @param y3 - The Y coord of the third point.
     */
    constructor(x?: number, y?: number, x2?: number, y2?: number, x3?: number, y3?: number);
    /**
     * Checks whether the x and y coordinates given are contained within this triangle
     * @example
     * ```ts
     * // Basic containment check
     * const triangle = new Triangle(0, 0, 100, 0, 50, 100);
     * const isInside = triangle.contains(25, 25); // true
     * ```
     * @remarks
     * - Uses barycentric coordinate system
     * - Works with any triangle shape
     * @param x - The X coordinate of the point to test
     * @param y - The Y coordinate of the point to test
     * @returns Whether the x/y coordinates are within this Triangle
     * @see {@link Triangle.strokeContains} For checking stroke intersection
     * @see {@link Triangle.getBounds} For getting containing rectangle
     */
    contains(x: number, y: number): boolean;
    /**
     * Checks whether the x and y coordinates given are contained within this triangle including the stroke.
     * @example
     * ```ts
     * // Basic stroke check
     * const triangle = new Triangle(0, 0, 100, 0, 50, 100);
     * const isOnStroke = triangle.strokeContains(25, 25, 4); // 4px line width
     *
     * // Check with different alignments
     * const innerStroke = triangle.strokeContains(25, 25, 4, 1);   // Inside
     * const centerStroke = triangle.strokeContains(25, 25, 4, 0.5); // Centered
     * const outerStroke = triangle.strokeContains(25, 25, 4, 0);   // Outside
     * ```
     * @param pointX - The X coordinate of the point to test
     * @param pointY - The Y coordinate of the point to test
     * @param strokeWidth - The width of the line to check
     * @param _alignment - The alignment of the stroke (1 = inner, 0.5 = centered, 0 = outer)
     * @returns Whether the x/y coordinates are within this triangle's stroke
     * @see {@link Triangle.contains} For checking fill containment
     * @see {@link Triangle.getBounds} For getting stroke bounds
     */
    strokeContains(pointX: number, pointY: number, strokeWidth: number, _alignment?: number): boolean;
    /**
     * Creates a clone of this Triangle
     * @example
     * ```ts
     * // Basic cloning
     * const original = new Triangle(0, 0, 100, 0, 50, 100);
     * const copy = original.clone();
     *
     * // Clone and modify
     * const modified = original.clone();
     * modified.x3 = 75;
     * modified.y3 = 150;
     *
     * // Verify independence
     * console.log(original.y3);  // 100
     * console.log(modified.y3);  // 150
     * ```
     * @returns A copy of the triangle
     * @see {@link Triangle.copyFrom} For copying into existing triangle
     * @see {@link Triangle.copyTo} For copying to another triangle
     */
    clone(): Triangle;
    /**
     * Copies another triangle to this one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new Triangle(0, 0, 100, 0, 50, 100);
     * const target = new Triangle();
     * target.copyFrom(source);
     *
     * // Chain with other operations
     * const triangle = new Triangle()
     *     .copyFrom(source)
     *     .getBounds(rect);
     * ```
     * @param triangle - The triangle to copy from
     * @returns Returns itself
     * @see {@link Triangle.copyTo} For copying to another triangle
     * @see {@link Triangle.clone} For creating new triangle copy
     */
    copyFrom(triangle: Triangle): this;
    /**
     * Copies this triangle to another one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new Triangle(0, 0, 100, 0, 50, 100);
     * const target = new Triangle();
     * source.copyTo(target);
     *
     * // Chain with other operations
     * const result = source
     *     .copyTo(new Triangle())
     *     .getBounds();
     * ```
     * @remarks
     * - Updates target triangle values
     * - Copies all point coordinates
     * - Returns target for chaining
     * - More efficient than clone()
     * @param triangle - The triangle to copy to
     * @returns Returns given parameter
     * @see {@link Triangle.copyFrom} For copying from another triangle
     * @see {@link Triangle.clone} For creating new triangle copy
     */
    copyTo(triangle: Triangle): Triangle;
    /**
     * Returns the framing rectangle of the triangle as a Rectangle object
     * @example
     * ```ts
     * // Basic bounds calculation
     * const triangle = new Triangle(0, 0, 100, 0, 50, 100);
     * const bounds = triangle.getBounds();
     * // bounds: x=0, y=0, width=100, height=100
     *
     * // Reuse existing rectangle
     * const rect = new Rectangle();
     * triangle.getBounds(rect);
     * ```
     * @param out - Optional rectangle to store the result
     * @returns The framing rectangle
     * @see {@link Rectangle} For rectangle properties
     * @see {@link Triangle.contains} For checking if a point is inside
     */
    getBounds(out?: Rectangle): Rectangle;
}
