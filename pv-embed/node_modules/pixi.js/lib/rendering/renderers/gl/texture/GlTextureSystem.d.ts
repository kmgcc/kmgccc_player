import { ExtensionType } from '../../../../extensions/Extensions';
import { Texture } from '../../shared/texture/Texture';
import { GlTexture } from './GlTexture';
import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { System } from '../../shared/system/System';
import type { CanvasGenerator, GetPixelsOutput } from '../../shared/texture/GenerateCanvas';
import type { TextureSource } from '../../shared/texture/sources/TextureSource';
import type { BindableTexture } from '../../shared/texture/Texture';
import type { GlRenderingContext } from '../context/GlRenderingContext';
import type { WebGLRenderer } from '../WebGLRenderer';
/**
 * The system for managing textures in WebGL.
 * @category rendering
 * @advanced
 */
export declare class GlTextureSystem implements System, CanvasGenerator {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "texture";
    };
    private readonly _renderer;
    private readonly _managedTextures;
    /**
     * @deprecated since 8.15.0
     */
    get managedTextures(): Readonly<TextureSource[]>;
    private _glSamplers;
    private _boundTextures;
    private _activeTextureLocation;
    private _boundSamplers;
    private readonly _uploads;
    private _gl;
    private _mapFormatToInternalFormat;
    private _mapFormatToType;
    private _mapFormatToFormat;
    private _mapViewDimensionToGlTarget;
    private _premultiplyAlpha;
    private readonly _useSeparateSamplers;
    constructor(renderer: WebGLRenderer);
    protected contextChange(gl: GlRenderingContext): void;
    /**
     * Initializes a texture source, if it has already been initialized nothing will happen.
     * @param source - The texture source to initialize.
     * @returns The initialized texture source.
     */
    initSource(source: TextureSource): void;
    bind(texture: BindableTexture, location?: number): void;
    bindSource(source: TextureSource, location?: number): void;
    private _bindSampler;
    unbind(texture: BindableTexture): void;
    private _activateLocation;
    private _initSource;
    protected onStyleChange(source: TextureSource): void;
    protected updateStyle(source: TextureSource, firstCreation: boolean): void;
    protected onSourceUnload(source: TextureSource, contextLost?: boolean): void;
    protected onSourceUpdate(source: TextureSource): void;
    protected onUpdateMipmaps(source: TextureSource, bind?: boolean): void;
    private _initEmptyTexture2D;
    private _initEmptyTexture2DArray;
    private _initEmptyTextureCube;
    /**
     * Applies a mip range to the currently-bound texture so WebGL2 considers the texture "mipmap complete"
     * for the declared `mipLevelCount` (especially important for partial mip chains rendered via FBO).
     * @param glTexture - The GL texture wrapper.
     * @param source - The texture source describing mipLevelCount.
     */
    private _applyMipRange;
    private _initSampler;
    private _getGlSampler;
    getGlSource(source: TextureSource): GlTexture;
    generateCanvas(texture: Texture): ICanvas;
    getPixels(texture: Texture): GetPixelsOutput;
    destroy(): void;
    resetState(): void;
}
