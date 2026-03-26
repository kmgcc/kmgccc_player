import { PlaneGeometry } from '../mesh-plane/PlaneGeometry';
import type { PlaneGeometryOptions } from '../mesh-plane/PlaneGeometry';
/**
 * Constructor options used for `PerspectivePlaneGeometry` instances.
 * @category scene
 * @advanced
 */
export interface PerspectivePlaneGeometryOptions extends PlaneGeometryOptions {
    /** The width of the plane */
    width: number;
    /** The height of the plane */
    height: number;
}
/**
 * A PerspectivePlaneGeometry allows you to draw a 2d plane with perspective. Where ever you move the corners
 * the texture will be projected to look like it is in 3d space. Great for mapping a 2D mesh into a 3D scene.
 *
 * IMPORTANT: This is not a full 3D mesh, it is a 2D mesh with a perspective projection applied to it :)
 *
 * ```js
 * const perspectivePlaneGeometry = new PerspectivePlaneGeometry({
 *  width: 100,
 *  height: 100,
 *  verticesX: 10,
 *  verticesY: 10,
 * });
 * ```
 * @see {@link PerspectivePlaneGeometry}
 * @category scene
 * @advanced
 */
export declare class PerspectivePlaneGeometry extends PlaneGeometry {
    /** The corner points of the quad you can modify these directly, if you do make sure to call `updateProjection` */
    corners: [number, number, number, number, number, number, number, number];
    private readonly _projectionMatrix;
    /**
     * @param options - Options to be applied to MeshPlane
     * @param options.width - The width of the plane
     * @param options.height - The height of the plane
     * @param options.verticesX - The amount of vertices on the x axis
     * @param options.verticesY - The amount of vertices on the y axis
     */
    constructor(options: PerspectivePlaneGeometryOptions);
    /**
     * Will set the corners of the quad to the given coordinates
     * Calculating the perspective so it looks correct!
     * @param x0 - x coordinate of the first corner
     * @param y0 - y coordinate of the first corner
     * @param x1 - x coordinate of the second corner
     * @param y1 - y coordinate of the second corner
     * @param x2 - x coordinate of the third corner
     * @param y2 - y coordinate of the third corner
     * @param x3 - x coordinate of the fourth corner
     * @param y3 - y coordinate of the fourth corner
     */
    setCorners(x0: number, y0: number, x1: number, y1: number, x2: number, y2: number, x3: number, y3: number): void;
    /** Update the projection matrix based on the corners */
    updateProjection(): void;
}
