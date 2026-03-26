import type { TextureSource } from '../../shared/texture/sources/TextureSource';
/**
 * A class which holds the canvas contexts and textures for a render target.
 * @category rendering
 * @ignore
 */
export declare class GpuRenderTarget {
    contexts: GPUCanvasContext[];
    msaaTextures: TextureSource[];
    msaa: boolean;
    msaaSamples: number;
    colorTargetCount: number;
    width: number;
    height: number;
    descriptor: GPURenderPassDescriptor;
}
