import { ExtensionType } from '../../../../extensions/Extensions';
import { type GPUData } from '../../../../scene/view/ViewContainer';
import { BindGroup } from '../shader/BindGroup';
import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { System } from '../../shared/system/System';
import type { CanvasGenerator, GetPixelsOutput } from '../../shared/texture/GenerateCanvas';
import type { TextureSource } from '../../shared/texture/sources/TextureSource';
import type { BindableTexture, Texture } from '../../shared/texture/Texture';
import type { TextureStyle } from '../../shared/texture/TextureStyle';
import type { GPU } from '../GpuDeviceSystem';
import type { WebGPURenderer } from '../WebGPURenderer';
/**
 * Stores GPU-specific data for a Texture instance in WebGL context.
 * @internal
 */
export declare class GPUTextureGpuData implements GPUData {
    gpuTexture: GPUTexture;
    textureView: GPUTextureView;
    constructor(gpuTexture: GPUTexture);
    /** Destroys this GPU data instance. */
    destroy(): void;
}
/**
 * The system that handles textures for the GPU.
 * @category rendering
 * @advanced
 */
export declare class GpuTextureSystem implements System, CanvasGenerator {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "texture";
    };
    protected CONTEXT_UID: number;
    private _gpuSamplers;
    private _bindGroupHash;
    private readonly _uploads;
    private _gpu;
    private _mipmapGenerator?;
    private readonly _renderer;
    private readonly _managedTextures;
    /**
     * @deprecated since 8.15.0
     */
    get managedTextures(): Readonly<TextureSource[]>;
    constructor(renderer: WebGPURenderer);
    protected contextChange(gpu: GPU): void;
    /**
     * Initializes a texture source, if it has already been initialized nothing will happen.
     * @param source - The texture source to initialize.
     * @returns The initialized texture source.
     */
    initSource(source: TextureSource): GPUTexture;
    private _initSource;
    protected onSourceUpdate(source: TextureSource): void;
    protected onUpdateMipmaps(source: TextureSource): void;
    protected onSourceUnload(source: TextureSource): void;
    protected onSourceResize(source: TextureSource): void;
    private _initSampler;
    getGpuSampler(sampler: TextureStyle): GPUSampler;
    getGpuSource(source: TextureSource): GPUTexture;
    /**
     * this returns s bind group for a specific texture, the bind group contains
     * - the texture source
     * - the texture style
     * - the texture matrix
     * This is cached so the bind group should only be created once per texture
     * @param texture - the texture you want the bindgroup for
     * @returns the bind group for the texture
     */
    getTextureBindGroup(texture: Texture): BindGroup;
    private _createTextureBindGroup;
    getTextureView(texture: BindableTexture): GPUTextureView;
    generateCanvas(texture: Texture): ICanvas;
    getPixels(texture: Texture): GetPixelsOutput;
    destroy(): void;
}
