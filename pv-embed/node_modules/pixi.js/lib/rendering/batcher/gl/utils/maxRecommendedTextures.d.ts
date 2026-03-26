/**
 * Returns the maximum number of textures that can be batched. This uses WebGL1's `MAX_TEXTURE_IMAGE_UNITS`.
 * The response for this is that to get this info via WebGPU, we would need to make a context, which
 * would make this function async, and we want to avoid that.
 * @private
 * @deprecated Use `Renderer.limits.maxBatchableTextures` instead.
 * @returns {number} The maximum number of textures that can be batched
 */
export declare function getMaxTexturesPerBatch(): number;
