import { TextureSource } from '../texture/sources/TextureSource';
import type { BindableTexture } from '../texture/Texture';
/**
 * Options for creating a render target.
 * @category rendering
 * @advanced
 */
export interface RenderTargetOptions {
    /** the width of the RenderTarget */
    width?: number;
    /** the height of the RenderTarget */
    height?: number;
    /** the resolution of the RenderTarget */
    resolution?: number;
    /** an array of textures, or a number indicating how many color textures there should be */
    colorTextures?: BindableTexture[] | number;
    /** should this render target have a stencil buffer? */
    stencil?: boolean;
    /** should this render target have a depth buffer? */
    depth?: boolean;
    /** a depth stencil texture that the depth and stencil outputs will be written to */
    depthStencilTexture?: BindableTexture | boolean;
    /** should this render target be antialiased? */
    antialias?: boolean;
    /** is this a root element, true if this is gl context owners render target */
    isRoot?: boolean;
}
/**
 * A class that describes what the renderers are rendering to.
 * This can be as simple as a Texture, or as complex as a multi-texture, multi-sampled render target.
 * Support for stencil and depth buffers is also included.
 *
 * If you need something more complex than a Texture to render to, you should use this class.
 * Under the hood, all textures you render to have a RenderTarget created on their behalf.
 * @category rendering
 * @advanced
 */
export declare class RenderTarget {
    /** The default options for a render target */
    static defaultOptions: RenderTargetOptions;
    /** unique id for this render target */
    readonly uid: number;
    /**
     * An array of textures that can be written to by the GPU - mostly this has one texture in Pixi, but you could
     * write to multiple if required! (eg deferred lighting)
     */
    colorTextures: TextureSource[];
    /** the stencil and depth buffer will right to this texture in WebGPU */
    depthStencilTexture: TextureSource;
    /** if true, will ensure a stencil buffer is added. For WebGPU, this will automatically create a depthStencilTexture */
    stencil: boolean;
    /** if true, will ensure a depth buffer is added. For WebGPU, this will automatically create a depthStencilTexture */
    depth: boolean;
    dirtyId: number;
    isRoot: boolean;
    private readonly _size;
    /** if true, then when the render target is destroyed, it will destroy all the textures that were created for it. */
    private readonly _managedColorTextures;
    /**
     * @param [descriptor] - Options for creating a render target.
     */
    constructor(descriptor?: RenderTargetOptions);
    get size(): [number, number];
    get width(): number;
    get height(): number;
    get pixelWidth(): number;
    get pixelHeight(): number;
    get resolution(): number;
    get colorTexture(): TextureSource;
    protected onSourceResize(source: TextureSource): void;
    /**
     * This will ensure a depthStencil texture is created for this render target.
     * Most likely called by the mask system to make sure we have stencil buffer added.
     * @internal
     */
    ensureDepthStencilTexture(): void;
    resize(width: number, height: number, resolution?: number, skipColorTexture?: boolean): void;
    destroy(): void;
}
