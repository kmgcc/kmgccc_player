import type { TextureSource } from '../../renderers/shared/texture/sources/TextureSource';
/**
 * Used by the batcher to build texture batches. Holds list of textures and their respective locations.
 * @category rendering
 * @advanced
 */
export declare class BatchTextureArray {
    /** Inside textures array. */
    textures: TextureSource[];
    /** Respective locations for textures. */
    ids: Record<number, number>;
    /** Number of filled elements. */
    count: number;
    constructor();
    /** Clear the textures and their locations. */
    clear(): void;
}
