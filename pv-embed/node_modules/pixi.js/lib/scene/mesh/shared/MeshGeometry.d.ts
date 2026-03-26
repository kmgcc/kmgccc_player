import { Geometry } from '../../../rendering/renderers/shared/geometry/Geometry';
import type { Topology } from '../../../rendering/renderers/shared/geometry/const';
import type { BatchMode } from '../../graphics/shared/GraphicsContext';
/**
 * Options for the mesh geometry.
 * @category scene
 * @advanced
 */
export interface MeshGeometryOptions {
    /** The positions of the mesh. */
    positions?: Float32Array;
    /** The UVs of the mesh. If not provided, they will be filled with 0 and match the size of the positions. */
    uvs?: Float32Array;
    /** The indices of the mesh. */
    indices?: Uint32Array;
    /** The topology of the mesh. */
    topology?: Topology;
    /** Whether to shrink the buffers to fit the data. */
    shrinkBuffersToFit?: boolean;
}
/**
 * A geometry used to batch multiple meshes with the same texture.
 * @category scene
 * @advanced
 */
export declare class MeshGeometry extends Geometry {
    static defaultOptions: MeshGeometryOptions;
    batchMode: BatchMode;
    /**
     * @param {MeshGeometryOptions} options - The options of the mesh geometry.
     */
    constructor(options: MeshGeometryOptions);
    /** @deprecated since 8.0.0 */
    constructor(positions: Float32Array, uvs: Float32Array, indices: Uint32Array);
    /** The positions of the mesh. */
    get positions(): Float32Array;
    /**
     * Set the positions of the mesh.
     * When setting the positions, its important that the uvs array is at least as long as the positions array.
     * otherwise the geometry will not be valid.
     * @param {Float32Array} value - The positions of the mesh.
     */
    set positions(value: Float32Array);
    /** The UVs of the mesh. */
    get uvs(): Float32Array;
    /**
     * Set the UVs of the mesh.
     * Its important that the uvs array you set is at least as long as the positions array.
     * otherwise the geometry will not be valid.
     * @param {Float32Array} value - The UVs of the mesh.
     */
    set uvs(value: Float32Array);
    /** The indices of the mesh. */
    get indices(): Uint32Array;
    set indices(value: Uint32Array);
}
