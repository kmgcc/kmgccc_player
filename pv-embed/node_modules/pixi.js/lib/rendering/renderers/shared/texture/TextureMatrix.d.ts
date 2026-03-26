import { Matrix } from '../../../../maths/matrix/Matrix';
import type { Texture } from './Texture';
/**
 * Class controls uv mapping from Texture normal space to BaseTexture normal space.
 *
 * Takes `trim` and `rotate` into account. May contain clamp settings for Meshes and TilingSprite.
 *
 * Can be used in Texture `uvMatrix` field, or separately, you can use different clamp settings on the same texture.
 * If you want to add support for texture region of certain feature or filter, that's what you're looking for.
 *
 * Takes track of Texture changes through `_lastTextureID` private field.
 * Use `update()` method call to track it from outside.
 * @see Texture
 * @see Mesh
 * @see TilingSprite
 * @category rendering
 * @advanced
 */
export declare class TextureMatrix {
    /**
     * Matrix operation that converts texture region coords to texture coords
     * @readonly
     */
    mapCoord: Matrix;
    /**
     * Changes frame clamping
     * Works with TilingSprite and Mesh
     * Change to 1.5 if you texture has repeated right and bottom lines, that leads to smoother borders
     * @default 0
     */
    clampOffset: number;
    /**
     * Changes frame clamping
     * Works with TilingSprite and Mesh
     * Change to -0.5 to add a pixel to the edge, recommended for transparent trimmed textures in atlas
     * @default 0.5
     */
    clampMargin: number;
    /**
     * Clamp region for normalized coords, left-top pixel center in xy , bottom-right in zw.
     * Calculated based on clampOffset.
     */
    readonly uClampFrame: Float32Array;
    /** Normalized clamp offset. Calculated based on clampOffset. */
    readonly uClampOffset: Float32Array;
    /**
     * Tracks Texture frame changes.
     * @ignore
     */
    _updateID: number;
    /**
     * Tracks Texture frame changes.
     * @protected
     */
    protected _textureID: number;
    protected _texture: Texture;
    /**
     * If texture size is the same as baseTexture.
     * @default false
     * @readonly
     */
    isSimple: boolean;
    /**
     * @param texture - observed texture
     * @param clampMargin - Changes frame clamping, 0.5 by default. Use -0.5 for extra border.
     */
    constructor(texture: Texture, clampMargin?: number);
    /** Texture property. */
    get texture(): Texture;
    set texture(value: Texture);
    /**
     * Multiplies uvs array to transform
     * @param uvs - mesh uvs
     * @param [out=uvs] - output
     * @returns - output
     */
    multiplyUvs(uvs: Float32Array, out?: Float32Array): Float32Array;
    /**
     * Updates matrices if texture was changed
     * @returns - whether or not it was updated
     */
    update(): boolean;
}
