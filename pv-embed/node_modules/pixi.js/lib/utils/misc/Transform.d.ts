import { Matrix } from '../../maths/matrix/Matrix';
import { ObservablePoint } from '../../maths/point/ObservablePoint';
import type { Observer } from '../../maths/point/ObservablePoint';
/**
 * Options for the {@link Transform} constructor.
 * @category utils
 * @advanced
 */
export interface TransformOptions {
    /** The matrix to use. */
    matrix?: Matrix;
    /**
     * The observer to use.
     * @advanced
     */
    observer?: {
        _onUpdate: (transform: Transform) => void;
    };
}
/**
 * The Transform class facilitates the manipulation of a 2D transformation matrix through
 * user-friendly properties: position, scale, rotation, skew, and pivot.
 * @example
 * ```ts
 * // Basic transform usage
 * const transform = new Transform();
 * transform.position.set(100, 100);
 * transform.rotation = Math.PI / 4; // 45 degrees
 * transform.scale.set(2, 2);
 *
 * // With pivot point
 * transform.pivot.set(50, 50);
 * transform.rotation = Math.PI; // Rotate around pivot
 *
 * // Matrix manipulation
 * const matrix = transform.matrix;
 * const position = { x: 0, y: 0 };
 * matrix.apply(position); // Transform point
 * ```
 * @remarks
 * - Manages 2D transformation properties
 * - Auto-updates matrix on changes
 * - Supports observable changes
 * - Common in display objects
 * @category utils
 * @standard
 * @see {@link Matrix} For direct matrix operations
 * @see {@link ObservablePoint} For point properties
 */
export declare class Transform {
    /**
     * The local transformation matrix.
     * @internal
     */
    _matrix: Matrix;
    /**
     * The coordinate of the object relative to the local coordinates of the parent.
     * @example
     * ```ts
     * // Basic position setting
     * transform.position.set(100, 100);
     *
     * // Individual coordinate access
     * transform.position.x = 50;
     * transform.position.y = 75;
     * ```
     */
    position: ObservablePoint;
    /**
     * The scale factor of the object.
     * @example
     * ```ts
     * // Uniform scaling
     * transform.scale.set(2, 2);
     *
     * // Non-uniform scaling
     * transform.scale.x = 2; // Stretch horizontally
     * transform.scale.y = 0.5; // Compress vertically
     * ```
     */
    scale: ObservablePoint;
    /**
     * The pivot point of the container that it rotates around.
     * @example
     * ```ts
     * // Center pivot
     * transform.pivot.set(sprite.width / 2, sprite.height / 2);
     *
     * // Corner rotation
     * transform.pivot.set(0, 0);
     * transform.rotation = Math.PI / 4; // 45 degrees
     * ```
     */
    pivot: ObservablePoint;
    /**
     * The skew amount, on the x and y axis.
     * @example
     * ```ts
     * // Apply horizontal skew
     * transform.skew.x = Math.PI / 6; // 30 degrees
     *
     * // Apply both skews
     * transform.skew.set(Math.PI / 6, Math.PI / 8);
     * ```
     */
    skew: ObservablePoint;
    /** The rotation amount. */
    protected _rotation: number;
    /**
     * The X-coordinate value of the normalized local X axis,
     * the first column of the local transformation matrix without a scale.
     */
    protected _cx: number;
    /**
     * The Y-coordinate value of the normalized local X axis,
     * the first column of the local transformation matrix without a scale.
     */
    protected _sx: number;
    /**
     * The X-coordinate value of the normalized local Y axis,
     * the second column of the local transformation matrix without a scale.
     */
    protected _cy: number;
    /**
     * The Y-coordinate value of the normalized local Y axis,
     * the second column of the local transformation matrix without a scale.
     */
    protected _sy: number;
    protected dirty: boolean;
    protected observer: Observer<Transform>;
    /**
     * @param options - Options for the transform.
     * @param options.matrix - The matrix to use.
     * @param options.observer - The observer to use.
     */
    constructor({ matrix, observer }?: TransformOptions);
    /**
     * The transformation matrix computed from the transform's properties.
     * Combines position, scale, rotation, skew, and pivot into a single matrix.
     * @example
     * ```ts
     * // Get current matrix
     * const matrix = transform.matrix;
     * console.log(matrix.toString());
     * ```
     * @readonly
     * @see {@link Matrix} For matrix operations
     * @see {@link Transform.setFromMatrix} For setting transform from matrix
     */
    get matrix(): Matrix;
    /**
     * Called when a value changes.
     * @param point
     * @internal
     */
    _onUpdate(point?: ObservablePoint): void;
    /** Called when the skew or the rotation changes. */
    protected updateSkew(): void;
    toString(): string;
    /**
     * Decomposes a matrix and sets the transforms properties based on it.
     * @example
     * ```ts
     * // Basic matrix decomposition
     * const transform = new Transform();
     * const matrix = new Matrix()
     *     .translate(100, 100)
     *     .rotate(Math.PI / 4)
     *     .scale(2, 2);
     *
     * transform.setFromMatrix(matrix);
     * console.log(transform.position.x); // 100
     * console.log(transform.rotation); // ~0.785 (π/4)
     * ```
     * @param matrix - The matrix to decompose
     * @see {@link Matrix#decompose} For the decomposition logic
     * @see {@link Transform#matrix} For getting the current matrix
     */
    setFromMatrix(matrix: Matrix): void;
    /**
     * The rotation of the object in radians.
     * @example
     * ```ts
     * // Basic rotation
     * transform.rotation = Math.PI / 4; // 45 degrees
     *
     * // Rotate around pivot point
     * transform.pivot.set(50, 50);
     * transform.rotation = Math.PI; // 180 degrees around pivot
     *
     * // Animate rotation
     * app.ticker.add(() => {
     *     transform.rotation += 0.1;
     * });
     * ```
     * @see {@link Transform#pivot} For rotation point
     * @see {@link Transform#skew} For skew effects
     */
    get rotation(): number;
    set rotation(value: number);
}
