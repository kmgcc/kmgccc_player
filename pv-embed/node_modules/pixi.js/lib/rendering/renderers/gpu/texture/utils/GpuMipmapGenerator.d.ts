/**
 * A class which generates mipmaps for a GPUTexture.
 * Thanks to toji for the original implementation
 * https://github.com/toji/web-texture-tool/blob/main/src/webgpu-mipmap-generator.js
 * @category rendering
 * @ignore
 */
export declare class GpuMipmapGenerator {
    device: GPUDevice;
    sampler: GPUSampler;
    pipelines: Record<string, GPURenderPipeline>;
    mipmapShaderModule: any;
    constructor(device: GPUDevice);
    private _getMipmapPipeline;
    /**
     * Generates mipmaps for the given GPUTexture from the data in level 0.
     * @param {module:External.GPUTexture} texture - Texture to generate mipmaps for.
     * @returns {module:External.GPUTexture} - The originally passed texture
     */
    generateMipmap(texture: GPUTexture): GPUTexture;
}
