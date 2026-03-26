import { type SHAPE_PRIMITIVE } from '../misc/const';
import { Rectangle } from './Rectangle';
import type { ShapePrimitive } from './ShapePrimitive';
/**
 * The `RoundedRectangle` object represents a rectangle with rounded corners.
 * Defined by position, dimensions and corner radius.
 * @example
 * ```ts
 * // Basic rectangle creation
 * const rect = new RoundedRectangle(100, 100, 200, 150, 20);
 * // Use as container hit area
 * container.hitArea = new RoundedRectangle(0, 0, 100, 100, 10);
 * // Check point containment
 * const isInside = rect.contains(mouseX, mouseY);
 * // Get bounds
 * const bounds = rect.getBounds();
 * ```
 * @remarks
 * - Position defined by top-left corner
 * - Radius clamped to half smallest dimension
 * - Common in UI elements
 * @see {@link Rectangle} For non-rounded rectangles
 * @category maths
 * @standard
 */
export declare class RoundedRectangle implements ShapePrimitive {
    /**
     * The X coordinate of the upper-left corner of the rounded rectangle
     * @example
     * ```ts
     * // Basic x position
     * const rect = new RoundedRectangle();
     * rect.x = 100;
     * ```
     * @default 0
     */
    x: number;
    /**
     * The Y coordinate of the upper-left corner of the rounded rectangle
     * @example
     * ```ts
     * // Basic y position
     * const rect = new RoundedRectangle();
     * rect.y = 100;
     * ```
     * @default 0
     */
    y: number;
    /**
     * The overall width of this rounded rectangle
     * @example
     * ```ts
     * // Basic width setting
     * const rect = new RoundedRectangle();
     * rect.width = 200; // Total width will be 200
     * ```
     * @default 0
     */
    width: number;
    /**
     * The overall height of this rounded rectangle
     * @example
     * ```ts
     * // Basic height setting
     * const rect = new RoundedRectangle();
     * rect.height = 150; // Total height will be 150
     * ```
     * @default 0
     */
    height: number;
    /**
     * Controls the radius of the rounded corners
     * @example
     * ```ts
     * // Basic radius setting
     * const rect = new RoundedRectangle(0, 0, 200, 150);
     * rect.radius = 20;
     *
     * // Clamp to maximum safe radius
     * rect.radius = Math.min(rect.width, rect.height) / 2;
     *
     * // Create pill shape
     * rect.radius = rect.height / 2;
     * ```
     * @remarks
     * - Automatically clamped to half of smallest dimension
     * - Common values: 0-20 for UI elements
     * - Higher values create more rounded corners
     * @default 20
     */
    radius: number;
    /**
     * The type of the object, mainly used to avoid `instanceof` checks
     * @example
     * ```ts
     * // Check shape type
     * const shape = new RoundedRectangle(0, 0, 100, 100, 20);
     * console.log(shape.type); // 'roundedRectangle'
     *
     * // Use in type guards
     * if (shape.type === 'roundedRectangle') {
     *     console.log(shape.radius);
     * }
     * ```
     * @readonly
     * @default 'roundedRectangle'
     * @see {@link SHAPE_PRIMITIVE} For all shape types
     */
    readonly type: SHAPE_PRIMITIVE;
    /**
     * @param x - The X coordinate of the upper-left corner of the rounded rectangle
     * @param y - The Y coordinate of the upper-left corner of the rounded rectangle
     * @param width - The overall width of this rounded rectangle
     * @param height - The overall height of this rounded rectangle
     * @param radius - Controls the radius of the rounded corners
     */
    constructor(x?: number, y?: number, width?: number, height?: number, radius?: number);
    /**
     * Returns the framing rectangle of the rounded rectangle as a Rectangle object
     * @example
     * ```ts
     * // Basic bounds calculation
     * const rect = new RoundedRectangle(100, 100, 200, 150, 20);
     * const bounds = rect.getBounds();
     * // bounds: x=100, y=100, width=200, height=150
     *
     * // Reuse existing rectangle
     * const out = new Rectangle();
     * rect.getBounds(out);
     * ```
     * @remarks
     * - Rectangle matches outer dimensions
     * - Ignores corner radius
     * @param out - Optional rectangle to store the result
     * @returns The framing rectangle
     * @see {@link Rectangle} For rectangle properties
     * @see {@link RoundedRectangle.contains} For checking if a point is inside
     */
    getBounds(out?: Rectangle): Rectangle;
    /**
     * Creates a clone of this Rounded Rectangle.
     * @example
     * ```ts
     * // Basic cloning
     * const original = new RoundedRectangle(100, 100, 200, 150, 20);
     * const copy = original.clone();
     *
     * // Clone and modify
     * const modified = original.clone();
     * modified.radius = 30;
     * modified.width *= 2;
     *
     * // Verify independence
     * console.log(original.radius);  // 20
     * console.log(modified.radius);  // 30
     * ```
     * @returns A copy of the rounded rectangle
     * @see {@link RoundedRectangle.copyFrom} For copying into existing rectangle
     * @see {@link RoundedRectangle.copyTo} For copying to another rectangle
     */
    clone(): RoundedRectangle;
    /**
     * Copies another rectangle to this one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new RoundedRectangle(100, 100, 200, 150, 20);
     * const target = new RoundedRectangle();
     * target.copyFrom(source);
     *
     * // Chain with other operations
     * const rect = new RoundedRectangle()
     *     .copyFrom(source)
     *     .getBounds(rect);
     * ```
     * @param rectangle - The rectangle to copy from
     * @returns Returns itself
     * @see {@link RoundedRectangle.copyTo} For copying to another rectangle
     * @see {@link RoundedRectangle.clone} For creating new rectangle copy
     */
    copyFrom(rectangle: RoundedRectangle): this;
    /**
     * Copies this rectangle to another one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new RoundedRectangle(100, 100, 200, 150, 20);
     * const target = new RoundedRectangle();
     * source.copyTo(target);
     *
     * // Chain with other operations
     * const result = source
     *     .copyTo(new RoundedRectangle())
     *     .getBounds();
     * ```
     * @param rectangle - The rectangle to copy to
     * @returns Returns given parameter
     * @see {@link RoundedRectangle.copyFrom} For copying from another rectangle
     * @see {@link RoundedRectangle.clone} For creating new rectangle copy
     */
    copyTo(rectangle: RoundedRectangle): RoundedRectangle;
    /**
     * Checks whether the x and y coordinates given are contained within this Rounded Rectangle
     * @example
     * ```ts
     * // Basic containment check
     * const rect = new RoundedRectangle(100, 100, 200, 150, 20);
     * const isInside = rect.contains(150, 125); // true
     * // Check corner radius
     * const corner = rect.contains(100, 100); // false if within corner curve
     * ```
     * @remarks
     * - Returns false if width/height is 0 or negative
     * - Handles rounded corners with radius check
     * @param x - The X coordinate of the point to test
     * @param y - The Y coordinate of the point to test
     * @returns Whether the x/y coordinates are within this Rounded Rectangle
     * @see {@link RoundedRectangle.strokeContains} For checking stroke intersection
     * @see {@link RoundedRectangle.getBounds} For getting containing rectangle
     */
    contains(x: number, y: number): boolean;
    /**
     * Checks whether the x and y coordinates given are contained within this rectangle including the stroke.
     * @example
     * ```ts
     * // Basic stroke check
     * const rect = new RoundedRectangle(100, 100, 200, 150, 20);
     * const isOnStroke = rect.strokeContains(150, 100, 4); // 4px line width
     *
     * // Check with different alignments
     * const innerStroke = rect.strokeContains(150, 100, 4, 1);   // Inside
     * const centerStroke = rect.strokeContains(150, 100, 4, 0.5); // Centered
     * const outerStroke = rect.strokeContains(150, 100, 4, 0);   // Outside
     * ```
     * @param pX - The X coordinate of the point to test
     * @param pY - The Y coordinate of the point to test
     * @param strokeWidth - The width of the line to check
     * @param alignment - The alignment of the stroke (1 = inner, 0.5 = centered, 0 = outer)
     * @returns Whether the x/y coordinates are within this rectangle's stroke
     * @see {@link RoundedRectangle.contains} For checking fill containment
     * @see {@link RoundedRectangle.getBounds} For getting stroke bounds
     */
    strokeContains(pX: number, pY: number, strokeWidth: number, alignment?: number): boolean;
    toString(): string;
}
