import { MeshGeometry } from '../mesh/shared/MeshGeometry';
import type { PointData } from '../../maths/point/PointData';
import type { MeshGeometryOptions } from '../mesh/shared/MeshGeometry';
/**
 * Constructor options used for `RopeGeometry` instances.
 * ```js
 * const ropeGeometry = new RopeGeometry({
 *    points: [new Point(0, 0), new Point(100, 0)],
 *    width: 10,
 *    textureScale: 0,
 * });
 * ```
 * @see {@link RopeGeometry}
 * @category scene
 * @advanced
 */
export interface RopeGeometryOptions {
    /** The width (i.e., thickness) of the rope. */
    width?: number;
    /** An array of points that determine the rope. */
    points?: PointData[];
    /**
     * Rope texture scale, if zero then the rope texture is stretched.
     * By default the rope texture will be stretched to match
     * rope length. If textureScale is positive this value will be treated as a scaling
     * factor and the texture will preserve its aspect ratio instead. To create a tiling rope
     * set baseTexture.wrapMode to 'repeat' and use a power of two texture,
     * then set textureScale=1 to keep the original texture pixel size.
     * In order to reduce alpha channel artifacts provide a larger texture and downsample -
     * i.e. set textureScale=0.5 to scale it down twice.
     */
    textureScale?: number;
}
/**
 * RopeGeometry allows you to draw a geometry across several points and then manipulate these points.
 * @example
 * import { Point, RopeGeometry } from 'pixi.js';
 *
 * for (let i = 0; i < 20; i++) {
 *     points.push(new Point(i * 50, 0));
 * };
 * const rope = new RopeGeometry(100, points);
 * @category scene
 * @advanced
 */
export declare class RopeGeometry extends MeshGeometry {
    /** Default options for RopeGeometry constructor. */
    static defaultOptions: RopeGeometryOptions & MeshGeometryOptions;
    /** An array of points that determine the rope. */
    points: PointData[];
    /** Rope texture scale, if zero then the rope texture is stretched. */
    readonly textureScale: number;
    /**
     * The width (i.e., thickness) of the rope.
     * @readonly
     * @internal
     */
    _width: number;
    /**
     * @param options - Options to be applied to rope geometry
     */
    constructor(options: RopeGeometryOptions);
    /**
     * The width (i.e., thickness) of the rope.
     * @readonly
     */
    get width(): number;
    /** Refreshes Rope indices and uvs */
    private _build;
    /** refreshes vertices of Rope mesh */
    updateVertices(): void;
    /** Refreshes Rope indices and uvs */
    update(): void;
}
