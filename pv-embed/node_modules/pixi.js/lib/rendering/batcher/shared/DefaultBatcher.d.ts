import { ExtensionType } from '../../../extensions/Extensions';
import { Batcher } from './Batcher';
import { BatchGeometry } from './BatchGeometry';
import { DefaultShader } from './DefaultShader';
import type { Matrix } from '../../../maths/matrix/Matrix';
import type { BatchableMeshElement, BatchableQuadElement, BatcherOptions } from './Batcher';
/**
 * Represents the common elements for default batch rendering.
 * This interface defines the properties that are used by the DefaultBatcher
 * to render elements efficiently in a batch.
 * @category rendering
 * @advanced
 */
export interface DefaultBatchElements {
    /**
     * The color of the element that will be multiplied with the texture color.
     * This is typically represented as a 32-bit integer in RGBA format.
     */
    color: number;
    /**
     * Determines whether the element should be rounded to the nearest pixel.
     * - 0: No rounding (default)
     * - 1: Round to nearest pixel
     * This can help with visual consistency, especially for pixel art styles.
     */
    roundPixels: 0 | 1;
    /**
     * The transform matrix of the element.
     * This matrix represents the position, scale, rotation, and skew of the element.
     */
    transform: Matrix;
}
/**
 * Represents a batchable quad element with default batch properties.
 * @category rendering
 * @advanced
 */
export interface DefaultBatchableQuadElement extends BatchableQuadElement, DefaultBatchElements {
}
/**
 * Represents a batchable mesh element with default batch properties.
 * @category rendering
 * @advanced
 */
export interface DefaultBatchableMeshElement extends BatchableMeshElement, DefaultBatchElements {
}
/**
 * The default batcher is used to batch quads and meshes. This batcher will batch the following elements:
 * - tints
 * - roundPixels
 * - texture
 * - transform
 * @category rendering
 * @advanced
 */
export declare class DefaultBatcher extends Batcher {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.Batcher];
        readonly name: "default";
    };
    geometry: BatchGeometry;
    shader: DefaultShader;
    name: "default";
    /** The size of one attribute. 1 = 32 bit. x, y, u, v, color, textureIdAndRound -> total = 6 */
    vertexSize: number;
    constructor(options: BatcherOptions);
    /**
     * Packs the attributes of a DefaultBatchableMeshElement into the provided views.
     * @param element - The DefaultBatchableMeshElement to pack.
     * @param float32View - The Float32Array view to pack into.
     * @param uint32View - The Uint32Array view to pack into.
     * @param index - The starting index in the views.
     * @param textureId - The texture ID to use.
     */
    packAttributes(element: DefaultBatchableMeshElement, float32View: Float32Array, uint32View: Uint32Array, index: number, textureId: number): void;
    /**
     * Packs the attributes of a DefaultBatchableQuadElement into the provided views.
     * @param element - The DefaultBatchableQuadElement to pack.
     * @param float32View - The Float32Array view to pack into.
     * @param uint32View - The Uint32Array view to pack into.
     * @param index - The starting index in the views.
     * @param textureId - The texture ID to use.
     */
    packQuadAttributes(element: DefaultBatchableQuadElement, float32View: Float32Array, uint32View: Uint32Array, index: number, textureId: number): void;
    /**
     * Updates the maximum number of textures that can be used in the shader.
     * @param maxTextures - The maximum number of textures that can be used in the shader.
     * @internal
     */
    _updateMaxTextures(maxTextures: number): void;
    destroy(): void;
}
