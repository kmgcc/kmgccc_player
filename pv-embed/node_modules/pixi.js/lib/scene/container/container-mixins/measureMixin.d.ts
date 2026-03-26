import { Bounds } from '../bounds/Bounds';
import type { Size } from '../../../maths/misc/Size';
import type { Container } from '../Container';
/**
 * A utility type that makes all properties of T optional except for the specified keys K.
 * @category utils
 * @internal
 */
export type Optional<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;
/** @ignore */
export interface MeasureMixinConstructor {
    /**
     * The width of the display object, in pixels.
     * @example
     * ```ts
     * new Container({ width: 100});
     * ```
     * @default 0
     */
    width?: number;
    /**
     * The height of the display object, in pixels.
     * @example
     * ```ts
     * new Container({ height: 100});
     * ```
     * @default 0
     */
    height?: number;
}
/**
 * The MeasureMixin interface provides methods for measuring and manipulating the size and bounds of a display object.
 * It includes methods to get and set the size of the object, retrieve its local bounds,
 * and calculate its global bounds.
 * @category scene
 * @advanced
 */
export interface MeasureMixin extends Required<MeasureMixinConstructor> {
    getSize(out?: Size): Size;
    setSize(width: number, height?: number): void;
    setSize(value: Optional<Size, 'height'>): void;
    /**
     * Retrieves the local bounds of the container as a Bounds object.
     * Uses cached values when possible for better performance.
     * @example
     * ```ts
     * // Basic bounds check
     * const bounds = container.getLocalBounds();
     * console.log(`Width: ${bounds.width}, Height: ${bounds.height}`);
     * // subsequent calls will reuse the cached bounds
     * const cachedBounds = container.getLocalBounds();
     * console.log(bounds === cachedBounds); // true
     * ```
     * @returns The bounding area
     * @see {@link Container#getBounds} For world space bounds
     * @see {@link Bounds} For bounds properties
     */
    getLocalBounds(): Bounds;
    /**
     * Calculates and returns the (world) bounds of the display object as a Rectangle.
     * Takes into account transforms and child bounds.
     * @example
     * ```ts
     * // Basic bounds calculation
     * const bounds = sprite.getBounds();
     * console.log(`World bounds: ${bounds.x}, ${bounds.y}, ${bounds.width}, ${bounds.height}`);
     *
     * // Reuse bounds object for performance
     * const recycleBounds = new Bounds();
     * sprite.getBounds(false, recycleBounds);
     *
     * // Skip update for performance
     * const fastBounds = sprite.getBounds(true);
     * ```
     * @remarks
     * - Includes transform calculations
     * - Updates scene graph by default
     * - Can reuse bounds objects
     * - Common in hit testing
     * @param {boolean} skipUpdate - Setting to `true` will stop the transforms of the scene graph from
     *  being updated. This means the calculation returned MAY be out of date BUT will give you a
     *  nice performance boost.
     * @param {Bounds} bounds - Optional bounds to store the result of the bounds calculation
     * @returns The minimum axis-aligned rectangle in world space that fits around this object
     * @see {@link Container#getLocalBounds} For untransformed bounds
     * @see {@link Bounds} For bounds properties
     */
    getBounds(skipUpdate?: boolean, bounds?: Bounds): Bounds;
    /** @private */
    _localBoundsCacheData: LocalBoundsCacheData;
    /** @private */
    _localBoundsCacheId: number;
    /** @private */
    _setWidth(width: number, localWidth: number): void;
    /** @private */
    _setHeight(height: number, localHeight: number): void;
}
interface LocalBoundsCacheData {
    data: number[];
    index: number;
    didChange: boolean;
    localBounds: Bounds;
}
/** @internal */
export declare const measureMixin: Partial<Container>;
export {};
