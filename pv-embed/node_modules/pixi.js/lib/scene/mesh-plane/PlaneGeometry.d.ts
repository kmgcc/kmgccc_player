import { MeshGeometry } from '../mesh/shared/MeshGeometry';
import type { MeshGeometryOptions } from '../mesh/shared/MeshGeometry';
/**
 * Constructor options used for `PlaneGeometry` instances.
 * ```js
 * const planeGeometry = new PlaneGeometry({
 *    width: 100,
 *    height: 100,
 *    verticesX: 10,
 *    verticesY: 10,
 * });
 * ```
 * @see {@link PlaneGeometry}
 * @category scene
 * @advanced
 */
export interface PlaneGeometryOptions {
    /** Width of plane */
    width?: number;
    /** Height of plane */
    height?: number;
    /** Number of vertices on x-axis */
    verticesX?: number;
    /** Number of vertices on y-axis */
    verticesY?: number;
}
/**
 * The PlaneGeometry allows you to draw a 2d plane
 * @category scene
 * @advanced
 */
export declare class PlaneGeometry extends MeshGeometry {
    static defaultOptions: PlaneGeometryOptions & MeshGeometryOptions;
    /** The number of vertices on x-axis */
    verticesX: number;
    /** The number of vertices on y-axis */
    verticesY: number;
    /** The width of plane */
    width: number;
    /** The height of plane */
    height: number;
    /**
     * @param {PlaneGeometryOptions} options - Options to be applied to plane geometry
     */
    constructor(options: PlaneGeometryOptions);
    /** @deprecated since 8.0.0 */
    constructor(width?: number, height?: number, verticesX?: number, verticesY?: number);
    /**
     * Refreshes plane coordinates
     * @param options - Options to be applied to plane geometry
     */
    build(options: PlaneGeometryOptions): void;
}
