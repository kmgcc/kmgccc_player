import EventEmitter from 'eventemitter3';
import { Rectangle } from '../../../../maths/shapes/Rectangle';
import { BufferImageSource } from './sources/BufferImageSource';
import { TextureSource } from './sources/TextureSource';
import { TextureMatrix } from './TextureMatrix';
import type { TextureResourceOrOptions } from './utils/textureFrom';
/**
 * Stores the width of the non-scalable borders, for example when used with {@link NineSlicePlane} texture.
 * @category rendering
 * @advanced
 */
export interface TextureBorders {
    /** left border in pixels */
    left: number;
    /** top border in pixels */
    top: number;
    /** right border in pixels */
    right: number;
    /** bottom border in pixels */
    bottom: number;
}
/**
 * The UVs data structure for a texture.
 * @category rendering
 * @advanced
 */
export type UVs = {
    x0: number;
    y0: number;
    x1: number;
    y1: number;
    x2: number;
    y2: number;
    x3: number;
    y3: number;
};
/**
 * The options that can be passed to a new Texture
 * @category rendering
 * @standard
 */
export interface TextureOptions<TextureSourceType extends TextureSource = TextureSource> {
    /** the underlying texture data that this texture will use  */
    source?: TextureSourceType;
    /** optional label, for debugging */
    label?: string;
    /** The rectangle frame of the texture to show */
    frame?: Rectangle;
    /** The area of original texture */
    orig?: Rectangle;
    /** Trimmed rectangle of original texture */
    trim?: Rectangle;
    /** Default anchor point used for sprite placement / rotation */
    defaultAnchor?: {
        x: number;
        y: number;
    };
    /** Default borders used for 9-slice scaling {@link NineSlicePlane}*/
    defaultBorders?: TextureBorders;
    /** indicates how the texture was rotated by texture packer. See {@link groupD8} */
    rotate?: number;
    /**
     * Set to true if you plan on modifying this texture's frame, UVs, or swapping its source at runtime.
     * This is false by default as it improves performance. Generally, it's recommended to create new
     * textures and swap those rather than modifying an existing texture's properties unless you are
     * working with a dynamic frames.
     * Not setting this to true when modifying the texture can lead to visual artifacts.
     *
     * If this is false and you modify the texture, you can manually update the sprite's texture by calling
     * `sprite.onViewUpdate()`.
     */
    dynamic?: boolean;
}
/**
 * A texture that can be bound to a shader as it has a texture source.
 * @category rendering
 * @advanced
 */
export interface BindableTexture {
    source: TextureSource;
}
/**
 * A texture source can be a string, an image, a video, a canvas, or a texture resource.
 * @category rendering
 * @advanced
 * @see {@link TextureSource}
 * @see {@link TextureResourceOrOptions}
 * @see {@link Texture.from}
 */
export type TextureSourceLike = TextureSource | TextureResourceOrOptions | string;
/**
 * A texture stores the information that represents an image or part of an image.
 *
 * A texture must have a loaded resource passed to it to work. It does not contain any
 * loading mechanisms.
 *
 * The Assets class can be used to load a texture from a file. This is the recommended
 * way as it will handle the loading and caching for you.
 *
 * ```js
 *
 * const texture = await Assets.load('assets/image.png');
 *
 * // once Assets has loaded the image it will be available via the from method
 * const sameTexture = Texture.from('assets/image.png');
 * // another way to access the texture once loaded
 * const sameAgainTexture = Assets.get('assets/image.png');
 *
 * const sprite1 = new Sprite(texture);
 *
 * ```
 *
 * It cannot be added to the display list directly; instead use it as the texture for a Sprite.
 * If no frame is provided for a texture, then the whole image is used.
 *
 * You can directly create a texture from an image and then reuse it multiple times like this :
 *
 * ```js
 * import { Sprite, Texture } from 'pixi.js';
 *
 * const texture = await Assets.load('assets/image.png');
 * const sprite1 = new Sprite(texture);
 * const sprite2 = new Sprite(texture);
 * ```
 *
 * If you didn't pass the texture frame to constructor, it enables `noFrame` mode:
 * it subscribes on baseTexture events, it automatically resizes at the same time as baseTexture.
 * @category rendering
 * @class
 * @standard
 */
export declare class Texture<TextureSourceType extends TextureSource = TextureSource> extends EventEmitter<{
    update: Texture;
    destroy: Texture;
}> implements BindableTexture {
    /**
     * Helper function that creates a returns Texture based on the source you provide.
     * The source should be loaded and ready to go. If not its best to grab the asset using Assets.
     * @param id - String or Source to create texture from
     * @param skipCache - Skip adding the texture to the cache
     * @returns The texture based on the Id provided
     */
    static from: (id: TextureSourceLike, skipCache?: boolean) => Texture;
    /** label used for debugging */
    label?: string;
    /** unique id for this texture */
    readonly uid: number;
    /**
     * Has the texture been destroyed?
     * @readonly
     */
    destroyed: boolean;
    /** @internal */
    _source: TextureSourceType;
    /**
     * Indicates whether the texture is rotated inside the atlas
     * set to 2 to compensate for texture packer rotation
     * set to 6 to compensate for spine packer rotation
     * can be used to rotate or mirror sprites
     * See {@link groupD8} for explanation
     */
    readonly rotate: number;
    /** A uvs object based on the given frame and the texture source */
    readonly uvs: UVs;
    /**
     * Anchor point that is used as default if sprite is created with this texture.
     * Changing the `defaultAnchor` at a later point of time will not update Sprite's anchor point.
     * @default {0,0}
     */
    readonly defaultAnchor?: {
        x: number;
        y: number;
    };
    /**
     * Default width of the non-scalable border that is used if 9-slice plane is created with this texture.
     * @since 7.2.0
     * @see NineSliceSprite
     */
    readonly defaultBorders?: TextureBorders;
    /**
     * This is the area of the BaseTexture image to actually copy to the Canvas / WebGL when rendering,
     * irrespective of the actual frame size or placement (which can be influenced by trimmed texture atlases)
     */
    readonly frame: Rectangle;
    /** This is the area of original texture, before it was put in atlas. */
    readonly orig: Rectangle;
    /**
     * This is the trimmed area of original texture, before it was put in atlas
     * Please call `updateUvs()` after you change coordinates of `trim` manually.
     */
    readonly trim: Rectangle;
    /**
     * Does this Texture have any frame data assigned to it?
     *
     * This mode is enabled automatically if no frame was passed inside constructor.
     *
     * In this mode texture is subscribed to baseTexture events, and fires `update` on any change.
     *
     * Beware, after loading or resize of baseTexture event can fired two times!
     * If you want more control, subscribe on baseTexture itself.
     * @example
     * texture.on('update', () => {});
     */
    noFrame: boolean;
    /**
     * Set to true if you plan on modifying the uvs of this texture.
     * When this is the case, sprites and other objects using the texture will
     * make sure to listen for changes to the uvs and update their vertices accordingly.
     */
    dynamic: boolean;
    private _textureMatrix;
    /** is it a texture? yes! used for type checking */
    readonly isTexture = true;
    /**
     * @param {TextureOptions} options - Options for the texture
     */
    constructor({ source, label, frame, orig, trim, defaultAnchor, defaultBorders, rotate, dynamic }?: TextureOptions<TextureSourceType>);
    set source(value: TextureSourceType);
    /** the underlying source of the texture (equivalent of baseTexture in v7) */
    get source(): TextureSourceType;
    /** returns a TextureMatrix instance for this texture. By default, that object is not created because its heavy. */
    get textureMatrix(): TextureMatrix;
    /** The width of the Texture in pixels. */
    get width(): number;
    /** The height of the Texture in pixels. */
    get height(): number;
    /** Call this function when you have modified the frame of this texture. */
    updateUvs(): void;
    /**
     * Destroys this texture
     * @param destroySource - Destroy the source when the texture is destroyed.
     */
    destroy(destroySource?: boolean): void;
    /**
     * Call this if you have modified the `texture outside` of the constructor.
     *
     * If you have modified this texture's source, you must separately call `texture.source.update()` to see those changes.
     */
    update(): void;
    /** @deprecated since 8.0.0 */
    get baseTexture(): TextureSource;
    /** an Empty Texture used internally by the engine */
    static EMPTY: Texture;
    /** a White texture used internally by the engine */
    static WHITE: Texture<BufferImageSource>;
}
