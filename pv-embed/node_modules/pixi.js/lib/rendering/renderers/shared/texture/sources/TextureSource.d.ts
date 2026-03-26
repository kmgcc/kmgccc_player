import EventEmitter from 'eventemitter3';
import { type GPUDataOwner } from '../../../../renderers/types';
import { type GlTexture } from '../../../gl/texture/GlTexture';
import { type GPUTextureGpuData } from '../../../gpu/texture/GpuTextureSystem';
import { type GCable, type GCData } from '../../GCSystem';
import { TextureStyle } from '../TextureStyle';
import type { BindResource } from '../../../gpu/shader/BindResource';
import type { ALPHA_MODES, SCALE_MODE, TEXTURE_DIMENSIONS, TEXTURE_FORMATS, TEXTURE_VIEW_DIMENSIONS, WRAP_MODE } from '../const';
import type { TextureStyleOptions } from '../TextureStyle';
import type { TextureResourceOrOptions } from '../utils/textureFrom';
/**
 * options for creating a new TextureSource
 * @category rendering
 * @advanced
 */
export interface TextureSourceOptions<T extends Record<string, any> = any> extends TextureStyleOptions {
    /**
     * the resource that will be uploaded to the GPU. This is where we get our pixels from
     * eg an ImageBimt / Canvas / Video etc
     */
    resource?: T;
    /** the pixel width of this texture source. This is the REAL pure number, not accounting resolution */
    width?: number;
    /** the pixel height of this texture source. This is the REAL pure number, not accounting resolution */
    height?: number;
    /** the resolution of the texture. */
    resolution?: number;
    /** the format that the texture data has */
    format?: TEXTURE_FORMATS;
    /**
     * Used by internal textures
     * @ignore
     */
    sampleCount?: number;
    /**
     * Only really affects RenderTextures.
     * Should we use antialiasing for this texture. It will look better, but may impact performance as a
     * Blit operation will be required to resolve the texture.
     */
    antialias?: boolean;
    /** how many dimensions does this texture have? currently v8 only supports 2d */
    dimensions?: TEXTURE_DIMENSIONS;
    /**
     * How this texture is viewed/sampled by shaders.
     *
     * This aligns with WebGPU's `GPUTextureViewDescriptor.dimension`. For example, cube maps are typically stored as a
     * 2D texture with 6 array layers (`dimensions: '2d'`) but viewed as `viewDimension: 'cube'`.
     */
    viewDimension?: TEXTURE_VIEW_DIMENSIONS;
    /**
     * The number of array layers for this texture source.
     *
     * This maps to WebGPU's `GPUTextureDescriptor.size.depthOrArrayLayers` and is used for array-backed textures
     * such as cube maps (6 layers).
     * @default 1
     * @advanced
     */
    arrayLayerCount?: number;
    /** The number of mip levels to generate for this texture. this is  overridden if autoGenerateMipmaps is true */
    mipLevelCount?: number;
    /**
     * Should we auto generate mipmaps for this texture? This will automatically generate mipmaps
     * for this texture when uploading to the GPU. Mipmapped textures take up more memory, but
     * can look better when scaled down.
     *
     * For performance reasons, it is recommended to NOT use this with RenderTextures, as they are often updated every frame.
     * If you do, make sure to call `updateMipmaps` after you update the texture.
     */
    autoGenerateMipmaps?: boolean;
    /** the alpha mode of the texture */
    alphaMode?: ALPHA_MODES;
    /** optional label, can be used for debugging */
    label?: string;
    /** If true, the Garbage Collector will unload this texture if it is not used after a period of time */
    autoGarbageCollect?: boolean;
    /** Used by RenderTexture.create to allow resizing. Not used by TextureSource itself. */
    dynamic?: boolean;
}
/**
 * A TextureSource stores the information that represents an image.
 * All textures have require TextureSource, which contains information about the source.
 * Therefore you can have many textures all using a single TextureSource (eg a sprite sheet)
 *
 * This is an class is extended depending on the source of the texture.
 * Eg if you are using an an image as your resource, then an ImageSource is used.
 * @category rendering
 * @advanced
 */
export declare class TextureSource<T extends Record<string, any> = any> extends EventEmitter<{
    change: BindResource;
    update: TextureSource;
    unload: TextureSource;
    destroy: TextureSource;
    resize: TextureSource;
    styleChange: TextureSource;
    updateMipmaps: TextureSource;
    error: Error;
}> implements BindResource, GPUDataOwner, GCable {
    protected readonly options: TextureSourceOptions<T>;
    /** The default options used when creating a new TextureSource. override these to add your own defaults */
    static defaultOptions: TextureSourceOptions;
    /** @internal */
    _gpuData: Record<number, GlTexture | GPUTextureGpuData>;
    /** GC tracking data, undefined if not being tracked */
    _gcData?: GCData;
    /** @internal */
    _gcLastUsed: number;
    /** unique id for this Texture source */
    readonly uid: number;
    /** optional label, can be used for debugging */
    label: string;
    /**
     * The resource type used by this TextureSource. This is used by the bind groups to determine
     * how to handle this resource.
     * @internal
     */
    readonly _resourceType = "textureSource";
    /**
     * i unique resource id, used by the bind group systems.
     * This can change if the texture is resized or its resource changes
     * @internal
     */
    _resourceId: number;
    /**
     * this is how the backends know how to upload this texture to the GPU
     * It changes depending on the resource type. Classes that extend TextureSource
     * should override this property.
     * @internal
     */
    uploadMethodId: string;
    /** @internal */
    _resolution: number;
    /** the pixel width of this texture source. This is the REAL pure number, not accounting resolution */
    pixelWidth: number;
    /** the pixel height of this texture source. This is the REAL pure number, not accounting resolution */
    pixelHeight: number;
    /**
     * the width of this texture source, accounting for resolution
     * eg pixelWidth 200, resolution 2, then width will be 100
     */
    width: number;
    /**
     * the height of this texture source, accounting for resolution
     * eg pixelHeight 200, resolution 2, then height will be 100
     */
    height: number;
    /**
     * the resource that will be uploaded to the GPU. This is where we get our pixels from
     * eg an ImageBimt / Canvas / Video etc
     */
    resource: T;
    /**
     * The number of samples of a multisample texture. This is always 1 for non-multisample textures.
     * To enable multisample for a texture, set antialias to true
     * @internal
     */
    sampleCount: number;
    /**
     * The number of mip levels to generate for this texture.
     * this is overridden if autoGenerateMipmaps is true. it is read only!
     */
    mipLevelCount: number;
    /**
     * Should we auto generate mipmaps for this texture? This will automatically generate mipmaps
     * for this texture when uploading to the GPU. Mipmapped textures take up more memory, but
     * can look better when scaled down.
     *
     * For performance reasons, it is recommended to NOT use this with RenderTextures, as they are often updated every frame.
     * If you do, make sure to call `updateMipmaps` after you update the texture.
     */
    autoGenerateMipmaps: boolean;
    /** the format that the texture data has */
    format: TEXTURE_FORMATS;
    /** how many dimensions does this texture have? currently v8 only supports 2d */
    dimension: TEXTURE_DIMENSIONS;
    /** how this texture is viewed/sampled by shaders (WebGPU view dimension) */
    viewDimension: TEXTURE_VIEW_DIMENSIONS;
    /** how many array layers this texture has (WebGPU depthOrArrayLayers) */
    arrayLayerCount: number;
    /** the alpha mode of the texture */
    alphaMode: ALPHA_MODES;
    private _style;
    /**
     * Only really affects RenderTextures.
     * Should we use antialiasing for this texture. It will look better, but may impact performance as a
     * Blit operation will be required to resolve the texture.
     */
    antialias: boolean;
    /**
     * Has the source been destroyed?
     * @readonly
     */
    destroyed: boolean;
    /**
     * Used by automatic texture Garbage Collection, stores last GC tick when it was bound
     * @protected
     */
    _touched: number;
    /**
     * Used by the batcher to build texture batches. faster to have the variable here!
     * @protected
     */
    _batchTick: number;
    /**
     * A temporary batch location for the texture batching. Here for performance reasons only!
     * @protected
     */
    _textureBindLocation: number;
    isPowerOfTwo: boolean;
    /** If true, the Garbage Collector will unload this texture if it is not used after a period of time */
    autoGarbageCollect: boolean;
    /**
     * used internally to know where a texture came from. Usually assigned by the asset loader!
     * @ignore
     */
    _sourceOrigin: string;
    /**
     * @param options - options for creating a new TextureSource
     */
    constructor(options?: TextureSourceOptions<T>);
    /** returns itself */
    get source(): TextureSource;
    /** the style of the texture */
    get style(): TextureStyle;
    set style(value: TextureStyle);
    /** Specifies the maximum anisotropy value clamp used by the sampler. */
    set maxAnisotropy(value: number);
    get maxAnisotropy(): number;
    /** setting this will set wrapModeU, wrapModeV and wrapModeW all at once! */
    get addressMode(): WRAP_MODE;
    set addressMode(value: WRAP_MODE);
    /** setting this will set wrapModeU, wrapModeV and wrapModeW all at once! */
    get repeatMode(): WRAP_MODE;
    set repeatMode(value: WRAP_MODE);
    /** Specifies the sampling behavior when the sample footprint is smaller than or equal to one texel. */
    get magFilter(): SCALE_MODE;
    set magFilter(value: SCALE_MODE);
    /** Specifies the sampling behavior when the sample footprint is larger than one texel. */
    get minFilter(): SCALE_MODE;
    set minFilter(value: SCALE_MODE);
    /** Specifies behavior for sampling between mipmap levels. */
    get mipmapFilter(): SCALE_MODE;
    set mipmapFilter(value: SCALE_MODE);
    /** Specifies the minimum and maximum levels of detail, respectively, used internally when sampling a texture. */
    get lodMinClamp(): number;
    set lodMinClamp(value: number);
    /** Specifies the minimum and maximum levels of detail, respectively, used internally when sampling a texture. */
    get lodMaxClamp(): number;
    set lodMaxClamp(value: number);
    private _onStyleChange;
    /** call this if you have modified the texture outside of the constructor */
    update(): void;
    /** Destroys this texture source */
    destroy(): void;
    /**
     * This will unload the Texture source from the GPU. This will free up the GPU memory
     * As soon as it is required fore rendering, it will be re-uploaded.
     */
    unload(): void;
    /** the width of the resource. This is the REAL pure number, not accounting resolution   */
    get resourceWidth(): number;
    /** the height of the resource. This is the REAL pure number, not accounting resolution */
    get resourceHeight(): number;
    /**
     * the resolution of the texture. Changing this number, will not change the number of pixels in the actual texture
     * but will the size of the texture when rendered.
     *
     * changing the resolution of this texture to 2 for example will make it appear twice as small when rendered (as pixel
     * density will have increased)
     */
    get resolution(): number;
    set resolution(resolution: number);
    /**
     * Resize the texture, this is handy if you want to use the texture as a render texture
     * @param width - the new width of the texture
     * @param height - the new height of the texture
     * @param resolution - the new resolution of the texture
     * @returns - if the texture was resized
     */
    resize(width?: number, height?: number, resolution?: number): boolean;
    /**
     * Lets the renderer know that this texture has been updated and its mipmaps should be re-generated.
     * This is only important for RenderTexture instances, as standard Texture instances will have their
     * mipmaps generated on upload. You should call this method after you make any change to the texture
     *
     * The reason for this is is can be quite expensive to update mipmaps for a texture. So by default,
     * We want you, the developer to specify when this action should happen.
     *
     * Generally you don't want to have mipmaps generated on Render targets that are changed every frame,
     */
    updateMipmaps(): void;
    set wrapMode(value: WRAP_MODE);
    get wrapMode(): WRAP_MODE;
    set scaleMode(value: SCALE_MODE);
    /** setting this will set magFilter,minFilter and mipmapFilter all at once!  */
    get scaleMode(): SCALE_MODE;
    /**
     * Refresh check for isPowerOfTwo texture based on size
     * @private
     */
    protected _refreshPOT(): void;
    static test(_resource: any): any;
    /**
     * A helper function that creates a new TextureSource based on the resource you provide.
     * @param resource - The resource to create the texture source from.
     */
    static from: (resource: TextureResourceOrOptions) => TextureSource;
}
