import type { Bounds } from '../../scene/container/bounds/Bounds';
import type { Matrix } from '../matrix/Matrix';
import type { SHAPE_PRIMITIVE } from '../misc/const';
import type { ShapePrimitive } from './ShapePrimitive';
export interface Rectangle extends PixiMixins.Rectangle {
}
/**
 * The `Rectangle` object represents a rectangular area defined by its position and dimensions.
 * Used for hit testing, bounds calculation, and general geometric operations.
 * @example
 * ```ts
 * // Basic rectangle creation
 * const rect = new Rectangle(100, 100, 200, 150);
 *
 * // Use as container bounds
 * container.hitArea = new Rectangle(0, 0, 100, 100);
 *
 * // Check point containment
 * const isInside = rect.contains(mouseX, mouseY);
 *
 * // Manipulate dimensions
 * rect.width *= 2;
 * rect.height += 50;
 * ```
 * @remarks
 * - Position defined by top-left corner (x,y)
 * - Dimensions defined by width and height
 * - Supports point and rectangle containment
 * - Common in UI and layout calculations
 * @see {@link Circle} For circular shapes
 * @see {@link Polygon} For complex shapes
 * @see {@link RoundedRectangle} For rounded corners
 * @category maths
 * @standard
 */
export declare class Rectangle implements ShapePrimitive {
    /**
     * The type of the object, mainly used to avoid `instanceof` checks
     * @example
     * ```ts
     * // Check shape type
     * const shape = new Rectangle(0, 0, 100, 100);
     * console.log(shape.type); // 'rectangle'
     *
     * // Use in type guards
     * if (shape.type === 'rectangle') {
     *     console.log(shape.width, shape.height);
     * }
     * ```
     * @readonly
     * @default 'rectangle'
     * @see {@link SHAPE_PRIMITIVE} For all shape types
     */
    readonly type: SHAPE_PRIMITIVE;
    /**
     * The X coordinate of the upper-left corner of the rectangle
     * @example
     * ```ts
     * // Basic x position
     * const rect = new Rectangle();
     * rect.x = 100;
     * ```
     * @default 0
     */
    x: number;
    /**
     * The Y coordinate of the upper-left corner of the rectangle
     * @example
     * ```ts
     * // Basic y position
     * const rect = new Rectangle();
     * rect.y = 100;
     * ```
     * @default 0
     */
    y: number;
    /**
     * The overall width of this rectangle
     * @example
     * ```ts
     * // Basic width setting
     * const rect = new Rectangle();
     * rect.width = 200;
     * ```
     * @default 0
     */
    width: number;
    /**
     * The overall height of this rectangle
     * @example
     * ```ts
     * // Basic height setting
     * const rect = new Rectangle();
     * rect.height = 150;
     * ```
     * @default 0
     */
    height: number;
    /**
     * @param x - The X coordinate of the upper-left corner of the rectangle
     * @param y - The Y coordinate of the upper-left corner of the rectangle
     * @param width - The overall width of the rectangle
     * @param height - The overall height of the rectangle
     */
    constructor(x?: string | number, y?: string | number, width?: string | number, height?: string | number);
    /**
     * Returns the left edge (x-coordinate) of the rectangle.
     * @example
     * ```ts
     * // Get left edge position
     * const rect = new Rectangle(100, 100, 200, 150);
     * console.log(rect.left); // 100
     *
     * // Use in alignment calculations
     * sprite.x = rect.left + padding;
     *
     * // Compare positions
     * if (point.x > rect.left) {
     *     console.log('Point is right of rectangle');
     * }
     * ```
     * @readonly
     * @returns The x-coordinate of the left edge
     * @see {@link Rectangle.right} For right edge position
     * @see {@link Rectangle.x} For direct x-coordinate access
     */
    get left(): number;
    /**
     * Returns the right edge (x + width) of the rectangle.
     * @example
     * ```ts
     * // Get right edge position
     * const rect = new Rectangle(100, 100, 200, 150);
     * console.log(rect.right); // 300
     *
     * // Align to right edge
     * sprite.x = rect.right - sprite.width;
     *
     * // Check boundaries
     * if (point.x < rect.right) {
     *     console.log('Point is inside right bound');
     * }
     * ```
     * @readonly
     * @returns The x-coordinate of the right edge
     * @see {@link Rectangle.left} For left edge position
     * @see {@link Rectangle.width} For width value
     */
    get right(): number;
    /**
     * Returns the top edge (y-coordinate) of the rectangle.
     * @example
     * ```ts
     * // Get top edge position
     * const rect = new Rectangle(100, 100, 200, 150);
     * console.log(rect.top); // 100
     *
     * // Position above rectangle
     * sprite.y = rect.top - sprite.height;
     *
     * // Check vertical position
     * if (point.y > rect.top) {
     *     console.log('Point is below top edge');
     * }
     * ```
     * @readonly
     * @returns The y-coordinate of the top edge
     * @see {@link Rectangle.bottom} For bottom edge position
     * @see {@link Rectangle.y} For direct y-coordinate access
     */
    get top(): number;
    /**
     * Returns the bottom edge (y + height) of the rectangle.
     * @example
     * ```ts
     * // Get bottom edge position
     * const rect = new Rectangle(100, 100, 200, 150);
     * console.log(rect.bottom); // 250
     *
     * // Stack below rectangle
     * sprite.y = rect.bottom + margin;
     *
     * // Check vertical bounds
     * if (point.y < rect.bottom) {
     *     console.log('Point is above bottom edge');
     * }
     * ```
     * @readonly
     * @returns The y-coordinate of the bottom edge
     * @see {@link Rectangle.top} For top edge position
     * @see {@link Rectangle.height} For height value
     */
    get bottom(): number;
    /**
     * Determines whether the Rectangle is empty (has no area).
     * @example
     * ```ts
     * // Check zero dimensions
     * const rect = new Rectangle(100, 100, 0, 50);
     * console.log(rect.isEmpty()); // true
     * ```
     * @returns True if the rectangle has no area
     * @see {@link Rectangle.width} For width value
     * @see {@link Rectangle.height} For height value
     */
    isEmpty(): boolean;
    /**
     * A constant empty rectangle. This is a new object every time the property is accessed.
     * @example
     * ```ts
     * // Get fresh empty rectangle
     * const empty = Rectangle.EMPTY;
     * console.log(empty.isEmpty()); // true
     * ```
     * @returns A new empty rectangle instance
     * @see {@link Rectangle.isEmpty} For empty state testing
     */
    static get EMPTY(): Rectangle;
    /**
     * Creates a clone of this Rectangle
     * @example
     * ```ts
     * // Basic cloning
     * const original = new Rectangle(100, 100, 200, 150);
     * const copy = original.clone();
     *
     * // Clone and modify
     * const modified = original.clone();
     * modified.width *= 2;
     * modified.height += 50;
     *
     * // Verify independence
     * console.log(original.width);  // 200
     * console.log(modified.width);  // 400
     * ```
     * @returns A copy of the rectangle
     * @see {@link Rectangle.copyFrom} For copying into existing rectangle
     * @see {@link Rectangle.copyTo} For copying to another rectangle
     */
    clone(): Rectangle;
    /**
     * Converts a Bounds object to a Rectangle object.
     * @example
     * ```ts
     * // Convert bounds to rectangle
     * const bounds = container.getBounds();
     * const rect = new Rectangle().copyFromBounds(bounds);
     * ```
     * @param bounds - The bounds to copy and convert to a rectangle
     * @returns Returns itself
     * @see {@link Bounds} For bounds object structure
     * @see {@link Rectangle.getBounds} For getting rectangle bounds
     */
    copyFromBounds(bounds: Bounds): this;
    /**
     * Copies another rectangle to this one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new Rectangle(100, 100, 200, 150);
     * const target = new Rectangle();
     * target.copyFrom(source);
     *
     * // Chain with other operations
     * const rect = new Rectangle()
     *     .copyFrom(source)
     *     .pad(10);
     * ```
     * @param rectangle - The rectangle to copy from
     * @returns Returns itself
     * @see {@link Rectangle.copyTo} For copying to another rectangle
     * @see {@link Rectangle.clone} For creating new rectangle copy
     */
    copyFrom(rectangle: Rectangle): Rectangle;
    /**
     * Copies this rectangle to another one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new Rectangle(100, 100, 200, 150);
     * const target = new Rectangle();
     * source.copyTo(target);
     *
     * // Chain with other operations
     * const result = source
     *     .copyTo(new Rectangle())
     *     .getBounds();
     * ```
     * @param rectangle - The rectangle to copy to
     * @returns Returns given parameter
     * @see {@link Rectangle.copyFrom} For copying from another rectangle
     * @see {@link Rectangle.clone} For creating new rectangle copy
     */
    copyTo(rectangle: Rectangle): Rectangle;
    /**
     * Checks whether the x and y coordinates given are contained within this Rectangle
     * @example
     * ```ts
     * // Basic containment check
     * const rect = new Rectangle(100, 100, 200, 150);
     * const isInside = rect.contains(150, 125); // true
     * // Check edge cases
     * console.log(rect.contains(100, 100)); // true (on edge)
     * console.log(rect.contains(300, 250)); // false (outside)
     * ```
     * @param x - The X coordinate of the point to test
     * @param y - The Y coordinate of the point to test
     * @returns Whether the x/y coordinates are within this Rectangle
     * @see {@link Rectangle.containsRect} For rectangle containment
     * @see {@link Rectangle.strokeContains} For checking stroke intersection
     */
    contains(x: number, y: number): boolean;
    /**
     * Checks whether the x and y coordinates given are contained within this rectangle including the stroke.
     * @example
     * ```ts
     * // Basic stroke check
     * const rect = new Rectangle(100, 100, 200, 150);
     * const isOnStroke = rect.strokeContains(150, 100, 4); // 4px line width
     *
     * // Check with different alignments
     * const innerStroke = rect.strokeContains(150, 100, 4, 1);   // Inside
     * const centerStroke = rect.strokeContains(150, 100, 4, 0.5); // Centered
     * const outerStroke = rect.strokeContains(150, 100, 4, 0);   // Outside
     * ```
     * @param x - The X coordinate of the point to test
     * @param y - The Y coordinate of the point to test
     * @param strokeWidth - The width of the line to check
     * @param alignment - The alignment of the stroke (1 = inner, 0.5 = centered, 0 = outer)
     * @returns Whether the x/y coordinates are within this rectangle's stroke
     * @see {@link Rectangle.contains} For checking fill containment
     * @see {@link Rectangle.getBounds} For getting stroke bounds
     */
    strokeContains(x: number, y: number, strokeWidth: number, alignment?: number): boolean;
    /**
     * Determines whether the `other` Rectangle transformed by `transform` intersects with `this` Rectangle object.
     * Returns true only if the area of the intersection is >0, this means that Rectangles
     * sharing a side are not overlapping. Another side effect is that an arealess rectangle
     * (width or height equal to zero) can't intersect any other rectangle.
     * @param {Rectangle} other - The Rectangle to intersect with `this`.
     * @param {Matrix} transform - The transformation matrix of `other`.
     * @returns {boolean} A value of `true` if the transformed `other` Rectangle intersects with `this`; otherwise `false`.
     */
    /**
     * Determines whether the `other` Rectangle transformed by `transform` intersects with `this` Rectangle object.
     *
     * Returns true only if the area of the intersection is greater than 0.
     * This means that rectangles sharing only a side are not considered intersecting.
     * @example
     * ```ts
     * // Basic intersection check
     * const rect1 = new Rectangle(0, 0, 100, 100);
     * const rect2 = new Rectangle(50, 50, 100, 100);
     * console.log(rect1.intersects(rect2)); // true
     *
     * // With transformation matrix
     * const matrix = new Matrix();
     * matrix.rotate(Math.PI / 4); // 45 degrees
     * console.log(rect1.intersects(rect2, matrix)); // Checks with rotation
     *
     * // Edge cases
     * const zeroWidth = new Rectangle(0, 0, 0, 100);
     * console.log(rect1.intersects(zeroWidth)); // false (no area)
     * ```
     * @remarks
     * - Returns true only if intersection area is > 0
     * - Rectangles sharing only a side are not intersecting
     * - Zero-area rectangles cannot intersect anything
     * - Supports optional transformation matrix
     * @param other - The Rectangle to intersect with `this`
     * @param transform - Optional transformation matrix of `other`
     * @returns True if the transformed `other` Rectangle intersects with `this`
     * @see {@link Rectangle.containsRect} For containment testing
     * @see {@link Rectangle.contains} For point testing
     */
    intersects(other: Rectangle, transform?: Matrix): boolean;
    /**
     * Pads the rectangle making it grow in all directions.
     *
     * If paddingY is omitted, both paddingX and paddingY will be set to paddingX.
     * @example
     * ```ts
     * // Basic padding
     * const rect = new Rectangle(100, 100, 200, 150);
     * rect.pad(10); // Adds 10px padding on all sides
     *
     * // Different horizontal and vertical padding
     * const uiRect = new Rectangle(0, 0, 100, 50);
     * uiRect.pad(20, 10); // 20px horizontal, 10px vertical
     * ```
     * @remarks
     * - Adjusts x/y by subtracting padding
     * - Increases width/height by padding * 2
     * - Common in UI layout calculations
     * - Chainable with other methods
     * @param paddingX - The horizontal padding amount
     * @param paddingY - The vertical padding amount
     * @returns Returns itself
     * @see {@link Rectangle.enlarge} For growing to include another rectangle
     * @see {@link Rectangle.fit} For shrinking to fit within another rectangle
     */
    pad(paddingX?: number, paddingY?: number): this;
    /**
     * Fits this rectangle around the passed one.
     * @example
     * ```ts
     * // Basic fitting
     * const container = new Rectangle(0, 0, 100, 100);
     * const content = new Rectangle(25, 25, 200, 200);
     * content.fit(container); // Clips to container bounds
     * ```
     * @param rectangle - The rectangle to fit around
     * @returns Returns itself
     * @see {@link Rectangle.enlarge} For growing to include another rectangle
     * @see {@link Rectangle.pad} For adding padding around the rectangle
     */
    fit(rectangle: Rectangle): this;
    /**
     * Enlarges rectangle so that its corners lie on a grid defined by resolution.
     * @example
     * ```ts
     * // Basic grid alignment
     * const rect = new Rectangle(10.2, 10.6, 100.8, 100.4);
     * rect.ceil(); // Aligns to whole pixels
     *
     * // Custom resolution grid
     * const uiRect = new Rectangle(5.3, 5.7, 50.2, 50.8);
     * uiRect.ceil(0.5); // Aligns to half pixels
     *
     * // Use with precision value
     * const preciseRect = new Rectangle(20.001, 20.999, 100.001, 100.999);
     * preciseRect.ceil(1, 0.01); // Handles small decimal variations
     * ```
     * @param resolution - The grid size to align to (1 = whole pixels)
     * @param eps - Small number to prevent floating point errors
     * @returns Returns itself
     * @see {@link Rectangle.fit} For constraining to bounds
     * @see {@link Rectangle.enlarge} For growing dimensions
     */
    ceil(resolution?: number, eps?: number): this;
    /**
     * Scales the rectangle's dimensions and position by the specified factors.
     * @example
     * ```ts
     * const rect = new Rectangle(50, 50, 100, 100);
     *
     * // Scale uniformly
     * rect.scale(0.5, 0.5);
     * // rect is now: x=25, y=25, width=50, height=50
     *
     * // non-uniformly
     * rect.scale(0.5, 1);
     * // rect is now: x=25, y=50, width=50, height=100
     * ```
     * @param x - The factor by which to scale the horizontal properties (x, width).
     * @param y - The factor by which to scale the vertical properties (y, height).
     * @returns Returns itself
     */
    scale(x: number, y?: number): this;
    /**
     * Enlarges this rectangle to include the passed rectangle.
     * @example
     * ```ts
     * // Basic enlargement
     * const rect = new Rectangle(50, 50, 100, 100);
     * const other = new Rectangle(0, 0, 200, 75);
     * rect.enlarge(other);
     * // rect is now: x=0, y=0, width=200, height=150
     *
     * // Use for bounding box calculation
     * const bounds = new Rectangle();
     * objects.forEach((obj) => {
     *     bounds.enlarge(obj.getBounds());
     * });
     * ```
     * @param rectangle - The rectangle to include
     * @returns Returns itself
     * @see {@link Rectangle.fit} For shrinking to fit within another rectangle
     * @see {@link Rectangle.pad} For adding padding around the rectangle
     */
    enlarge(rectangle: Rectangle): this;
    /**
     * Returns the framing rectangle of the rectangle as a Rectangle object
     * @example
     * ```ts
     * // Basic bounds retrieval
     * const rect = new Rectangle(100, 100, 200, 150);
     * const bounds = rect.getBounds();
     *
     * // Reuse existing rectangle
     * const out = new Rectangle();
     * rect.getBounds(out);
     * ```
     * @param out - Optional rectangle to store the result
     * @returns The framing rectangle
     * @see {@link Rectangle.copyFrom} For direct copying
     * @see {@link Rectangle.clone} For creating new copy
     */
    getBounds(out?: Rectangle): Rectangle;
    /**
     * Determines whether another Rectangle is fully contained within this Rectangle.
     *
     * Rectangles that occupy the same space are considered to be containing each other.
     *
     * Rectangles without area (width or height equal to zero) can't contain anything,
     * not even other arealess rectangles.
     * @example
     * ```ts
     * // Check if one rectangle contains another
     * const container = new Rectangle(0, 0, 100, 100);
     * const inner = new Rectangle(25, 25, 50, 50);
     *
     * console.log(container.containsRect(inner)); // true
     *
     * // Check overlapping rectangles
     * const partial = new Rectangle(75, 75, 50, 50);
     * console.log(container.containsRect(partial)); // false
     *
     * // Zero-area rectangles
     * const empty = new Rectangle(0, 0, 0, 100);
     * console.log(container.containsRect(empty)); // false
     * ```
     * @param other - The Rectangle to check for containment
     * @returns True if other is fully contained within this Rectangle
     * @see {@link Rectangle.contains} For point containment
     * @see {@link Rectangle.intersects} For overlap testing
     */
    containsRect(other: Rectangle): boolean;
    /**
     * Sets the position and dimensions of the rectangle.
     * @example
     * ```ts
     * // Basic usage
     * const rect = new Rectangle();
     * rect.set(100, 100, 200, 150);
     *
     * // Chain with other operations
     * const bounds = new Rectangle()
     *     .set(0, 0, 100, 100)
     *     .pad(10);
     * ```
     * @param x - The X coordinate of the upper-left corner of the rectangle
     * @param y - The Y coordinate of the upper-left corner of the rectangle
     * @param width - The overall width of the rectangle
     * @param height - The overall height of the rectangle
     * @returns Returns itself for method chaining
     * @see {@link Rectangle.copyFrom} For copying from another rectangle
     * @see {@link Rectangle.clone} For creating a new copy
     */
    set(x: number, y: number, width: number, height: number): this;
    toString(): string;
}
