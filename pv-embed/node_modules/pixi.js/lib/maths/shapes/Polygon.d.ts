import { Rectangle } from './Rectangle';
import type { SHAPE_PRIMITIVE } from '../misc/const';
import type { PointData } from '../point/PointData';
import type { ShapePrimitive } from './ShapePrimitive';
/**
 * A class to define a shape via user defined coordinates.
 * Used for creating complex shapes and hit areas with custom points.
 * @example
 * ```ts
 * // Create polygon from array of points
 * const polygon1 = new Polygon([
 *     new Point(0, 0),
 *     new Point(0, 100),
 *     new Point(100, 100)
 * ]);
 *
 * // Create from array of coordinates
 * const polygon2 = new Polygon([0, 0, 0, 100, 100, 100]);
 *
 * // Create from sequence of points
 * const polygon3 = new Polygon(
 *     new Point(0, 0),
 *     new Point(0, 100),
 *     new Point(100, 100)
 * );
 *
 * // Create from sequence of coordinates
 * const polygon4 = new Polygon(0, 0, 0, 100, 100, 100);
 *
 * // Use as container hit area
 * container.hitArea = new Polygon([0, 0, 100, 0, 50, 100]);
 * ```
 * @see {@link Point} For point objects used in construction
 * @category maths
 * @standard
 */
export declare class Polygon implements ShapePrimitive {
    /**
     * An array of the points of this polygon stored as a flat array of numbers.
     * @example
     * ```ts
     * // Access points directly
     * const polygon = new Polygon([0, 0, 100, 0, 50, 100]);
     * console.log(polygon.points); // [0, 0, 100, 0, 50, 100]
     *
     * // Modify points
     * polygon.points[0] = 10; // Move first x coordinate
     * polygon.points[1] = 10; // Move first y coordinate
     * ```
     * @remarks
     * - Stored as [x1, y1, x2, y2, ...]
     * - Each pair represents a vertex
     * - Length is always even
     * - Can be modified directly
     */
    points: number[];
    /**
     * Indicates if the polygon path is closed.
     * @example
     * ```ts
     * // Create open polygon
     * const polygon = new Polygon([0, 0, 100, 0, 50, 100]);
     * polygon.closePath = false;
     *
     * // Check path state
     * if (polygon.closePath) {
     *     // Last point connects to first
     * }
     * ```
     * @remarks
     * - True by default
     * - False after moveTo
     * - True after closePath
     * @default true
     */
    closePath: boolean;
    /**
     * The type of the object, mainly used to avoid `instanceof` checks
     * @example
     * ```ts
     * // Check shape type
     * const shape = new Polygon([0, 0, 100, 0, 50, 100]);
     * console.log(shape.type); // 'polygon'
     *
     * // Use in type guards
     * if (shape.type === 'polygon') {
     *     // TypeScript knows this is a Polygon
     *     console.log(shape.points.length);
     * }
     * ```
     * @readonly
     * @default 'polygon'
     * @see {@link SHAPE_PRIMITIVE} For all shape types
     */
    readonly type: SHAPE_PRIMITIVE;
    constructor(points: PointData[] | number[]);
    constructor(...points: PointData[] | number[]);
    /**
     * Determines whether the polygon's points are arranged in a clockwise direction.
     * Uses the shoelace formula (surveyor's formula) to calculate the signed area.
     *
     * A positive area indicates clockwise winding, while negative indicates counter-clockwise.
     *
     * The formula sums up the cross products of adjacent vertices:
     * For each pair of adjacent points (x1,y1) and (x2,y2), we calculate (x1*y2 - x2*y1)
     * The final sum divided by 2 gives the signed area - positive for clockwise.
     * @example
     * ```ts
     * // Check polygon winding
     * const polygon = new Polygon([0, 0, 100, 0, 50, 100]);
     * console.log(polygon.isClockwise()); // Check direction
     *
     * // Use in path construction
     * const hole = new Polygon([25, 25, 75, 25, 75, 75, 25, 75]);
     * if (hole.isClockwise() === shape.isClockwise()) {
     *     hole.points.reverse(); // Reverse for proper hole winding
     * }
     * ```
     * @returns `true` if the polygon's points are arranged clockwise, `false` if counter-clockwise
     */
    isClockwise(): boolean;
    /**
     * Checks if this polygon completely contains another polygon.
     * Used for detecting holes in shapes, like when parsing SVG paths.
     * @example
     * ```ts
     * // Basic containment check
     * const outerSquare = new Polygon([0,0, 100,0, 100,100, 0,100]); // A square
     * const innerSquare = new Polygon([25,25, 75,25, 75,75, 25,75]); // A smaller square inside
     *
     * outerSquare.containsPolygon(innerSquare); // Returns true
     * innerSquare.containsPolygon(outerSquare); // Returns false
     * ```
     * @remarks
     * - Uses bounds check for quick rejection
     * - Tests all points for containment
     * @param polygon - The polygon to test for containment
     * @returns True if this polygon completely contains the other polygon
     * @see {@link Polygon.contains} For single point testing
     * @see {@link Polygon.getBounds} For bounds calculation
     */
    containsPolygon(polygon: Polygon): boolean;
    /**
     * Creates a clone of this polygon.
     * @example
     * ```ts
     * // Basic cloning
     * const original = new Polygon([0, 0, 100, 0, 50, 100]);
     * const copy = original.clone();
     *
     * // Clone and modify
     * const modified = original.clone();
     * modified.points[0] = 10; // Modify first x coordinate
     * ```
     * @returns A copy of the polygon
     * @see {@link Polygon.copyFrom} For copying into existing polygon
     * @see {@link Polygon.copyTo} For copying to another polygon
     */
    clone(): Polygon;
    /**
     * Checks whether the x and y coordinates passed to this function are contained within this polygon.
     * Uses raycasting algorithm for point-in-polygon testing.
     * @example
     * ```ts
     * // Basic containment check
     * const polygon = new Polygon([0, 0, 100, 0, 50, 100]);
     * const isInside = polygon.contains(25, 25); // true
     * ```
     * @param x - The X coordinate of the point to test
     * @param y - The Y coordinate of the point to test
     * @returns Whether the x/y coordinates are within this polygon
     * @see {@link Polygon.strokeContains} For checking stroke intersection
     * @see {@link Polygon.containsPolygon} For polygon-in-polygon testing
     */
    contains(x: number, y: number): boolean;
    /**
     * Checks whether the x and y coordinates given are contained within this polygon including the stroke.
     * @example
     * ```ts
     * // Basic stroke check
     * const polygon = new Polygon([0, 0, 100, 0, 50, 100]);
     * const isOnStroke = polygon.strokeContains(25, 25, 4); // 4px line width
     *
     * // Check with different alignments
     * const innerStroke = polygon.strokeContains(25, 25, 4, 1);   // Inside
     * const centerStroke = polygon.strokeContains(25, 25, 4, 0.5); // Centered
     * const outerStroke = polygon.strokeContains(25, 25, 4, 0);   // Outside
     * ```
     * @param x - The X coordinate of the point to test
     * @param y - The Y coordinate of the point to test
     * @param strokeWidth - The width of the line to check
     * @param alignment - The alignment of the stroke (1 = inner, 0.5 = centered, 0 = outer)
     * @returns Whether the x/y coordinates are within this polygon's stroke
     * @see {@link Polygon.contains} For checking fill containment
     * @see {@link Polygon.getBounds} For getting stroke bounds
     */
    strokeContains(x: number, y: number, strokeWidth: number, alignment?: number): boolean;
    /**
     * Returns the framing rectangle of the polygon as a Rectangle object.
     * @example
     * ```ts
     * // Basic bounds calculation
     * const polygon = new Polygon([0, 0, 100, 0, 50, 100]);
     * const bounds = polygon.getBounds();
     * // bounds: x=0, y=0, width=100, height=100
     *
     * // Reuse existing rectangle
     * const rect = new Rectangle();
     * polygon.getBounds(rect);
     * ```
     * @param out - Optional rectangle to store the result
     * @returns The framing rectangle
     * @see {@link Rectangle} For rectangle properties
     * @see {@link Polygon.contains} For checking if a point is inside
     */
    getBounds(out?: Rectangle): Rectangle;
    /**
     * Copies another polygon to this one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new Polygon([0, 0, 100, 0, 50, 100]);
     * const target = new Polygon();
     * target.copyFrom(source);
     * ```
     * @param polygon - The polygon to copy from
     * @returns Returns itself
     * @see {@link Polygon.copyTo} For copying to another polygon
     * @see {@link Polygon.clone} For creating new polygon copy
     */
    copyFrom(polygon: Polygon): this;
    /**
     * Copies this polygon to another one.
     * @example
     * ```ts
     * // Basic copying
     * const source = new Polygon([0, 0, 100, 0, 50, 100]);
     * const target = new Polygon();
     * source.copyTo(target);
     * ```
     * @param polygon - The polygon to copy to
     * @returns Returns given parameter
     * @see {@link Polygon.copyFrom} For copying from another polygon
     * @see {@link Polygon.clone} For creating new polygon copy
     */
    copyTo(polygon: Polygon): Polygon;
    toString(): string;
    /**
     * Get the last X coordinate of the polygon.
     * @example
     * ```ts
     * // Basic coordinate access
     * const polygon = new Polygon([0, 0, 100, 200, 300, 400]);
     * console.log(polygon.lastX); // 300
     * ```
     * @readonly
     * @returns The x-coordinate of the last vertex
     * @see {@link Polygon.lastY} For last Y coordinate
     * @see {@link Polygon.points} For raw points array
     */
    get lastX(): number;
    /**
     * Get the last Y coordinate of the polygon.
     * @example
     * ```ts
     * // Basic coordinate access
     * const polygon = new Polygon([0, 0, 100, 200, 300, 400]);
     * console.log(polygon.lastY); // 400
     * ```
     * @readonly
     * @returns The y-coordinate of the last vertex
     * @see {@link Polygon.lastX} For last X coordinate
     * @see {@link Polygon.points} For raw points array
     */
    get lastY(): number;
    /**
     * Get the last X coordinate of the polygon.
     * @readonly
     * @deprecated since 8.11.0, use {@link Polygon.lastX} instead.
     */
    get x(): number;
    /**
     * Get the last Y coordinate of the polygon.
     * @readonly
     * @deprecated since 8.11.0, use {@link Polygon.lastY} instead.
     */
    get y(): number;
    /**
     * Get the first X coordinate of the polygon.
     * @example
     * ```ts
     * // Basic coordinate access
     * const polygon = new Polygon([0, 0, 100, 200, 300, 400]);
     * console.log(polygon.x); // 0
     * ```
     * @readonly
     * @returns The x-coordinate of the first vertex
     * @see {@link Polygon.startY} For first Y coordinate
     * @see {@link Polygon.points} For raw points array
     */
    get startX(): number;
    /**
     * Get the first Y coordinate of the polygon.
     * @example
     * ```ts
     * // Basic coordinate access
     * const polygon = new Polygon([0, 0, 100, 200, 300, 400]);
     * console.log(polygon.y); // 0
     * ```
     * @readonly
     * @returns The y-coordinate of the first vertex
     * @see {@link Polygon.startX} For first X coordinate
     * @see {@link Polygon.points} For raw points array
     */
    get startY(): number;
}
