import { TextureSource } from './sources/TextureSource';
import { Texture } from './Texture';
import { TextureStyle } from './TextureStyle';
import type { TextureSourceOptions } from './sources/TextureSource';
/**
 * Texture pool, used by FilterSystem and plugins.
 *
 * Stores collection of temporary pow2 or screen-sized renderTextures
 *
 * If you use custom RenderTexturePool for your filters, you can use methods
 * `getFilterTexture` and `returnFilterTexture` same as in default pool
 * @category rendering
 * @advanced
 */
export declare class TexturePoolClass {
    /** The default options for texture pool */
    textureOptions: TextureSourceOptions;
    /** The default texture style for the pool */
    textureStyle: TextureStyle;
    /**
     * Allow renderTextures of the same size as screen, not just pow2
     *
     * Automatically sets to true after `setScreenSize`
     * @default false
     */
    enableFullScreen: boolean;
    private _texturePool;
    private _poolKeyHash;
    /**
     * @param textureOptions - options that will be passed to BaseRenderTexture constructor
     * @param {SCALE_MODE} [textureOptions.scaleMode] - See {@link SCALE_MODE} for possible values.
     */
    constructor(textureOptions?: TextureSourceOptions);
    /**
     * Creates texture with params that were specified in pool constructor.
     * @param pixelWidth - Width of texture in pixels.
     * @param pixelHeight - Height of texture in pixels.
     * @param antialias
     * @param autoGenerateMipmaps - Whether to automatically generate mipmaps for this texture
     */
    createTexture(pixelWidth: number, pixelHeight: number, antialias: boolean, autoGenerateMipmaps: boolean): Texture;
    /**
     * Gets a Power-of-Two render texture or fullScreen texture
     * @param frameWidth - The minimum width of the render texture.
     * @param frameHeight - The minimum height of the render texture.
     * @param resolution - The resolution of the render texture.
     * @param antialias
     * @param autoGenerateMipmaps - Whether to automatically generate mipmaps. Defaults to false.
     * @returns The new render texture.
     */
    getOptimalTexture(frameWidth: number, frameHeight: number, resolution: number, antialias: boolean, autoGenerateMipmaps?: boolean): Texture;
    /**
     * Gets a pooled texture matching the dimensions and resolution of the given texture.
     *
     * This is a convenience wrapper around {@link TexturePoolClass#getOptimalTexture|getOptimalTexture}
     * that copies width, height, and resolution from an existing texture. Useful when a filter needs
     * a temporary texture the same size as its input (e.g., for multi-pass blur).
     * @param texture - The texture whose dimensions to match.
     * @param antialias - Whether to use antialias on the pooled texture. Defaults to `false`.
     * @returns A pooled texture with power-of-two backing dimensions at the source resolution.
     */
    getSameSizeTexture(texture: Texture, antialias?: boolean): Texture<TextureSource<any>>;
    /**
     * Returns a texture to the pool so it can be reused by future
     * {@link TexturePoolClass#getOptimalTexture|getOptimalTexture}
     * or {@link TexturePoolClass#getSameSizeTexture|getSameSizeTexture} calls.
     *
     * If you modified the texture's style after obtaining it (e.g., changed filtering or wrapping),
     * pass `resetStyle = true` to restore the pool's default {@link TexturePoolClass#textureStyle|textureStyle}.
     * This prevents style changes from leaking into subsequent consumers of the same pooled texture.
     * @param renderTexture - The texture to return to the pool.
     * @param resetStyle - When `true`, replaces the texture source's style with the pool default. Defaults to `false`.
     */
    returnTexture(renderTexture: Texture, resetStyle?: boolean): void;
    /**
     * Clears the pool.
     * @param destroyTextures - Destroy all stored textures.
     */
    clear(destroyTextures?: boolean): void;
}
/**
 * The default texture pool instance.
 * @category rendering
 * @advanced
 */
export declare const TexturePool: TexturePoolClass;
