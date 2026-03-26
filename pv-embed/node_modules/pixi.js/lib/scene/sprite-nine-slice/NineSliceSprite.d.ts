import { ObservablePoint } from '../../maths/point/ObservablePoint';
import { type PointData } from '../../maths/point/PointData';
import { Texture } from '../../rendering/renderers/shared/texture/Texture';
import { ViewContainer, type ViewContainerOptions } from '../view/ViewContainer';
import { type NineSliceSpriteGpuData } from './NineSliceSpritePipe';
import './init';
import type { Size } from '../../maths/misc/Size';
import type { View } from '../../rendering/renderers/shared/view/View';
import type { Optional } from '../container/container-mixins/measureMixin';
import type { DestroyOptions } from '../container/destroyTypes';
/**
 * Constructor options used for `NineSliceSprite` instances.
 * Defines how the sprite's texture is divided and scaled in nine sections.
 * <pre>
 *      A                          B
 *    +---+----------------------+---+
 *  C | 1 |          2           | 3 |
 *    +---+----------------------+---+
 *    |   |                      |   |
 *    | 4 |          5           | 6 |
 *    |   |                      |   |
 *    +---+----------------------+---+
 *  D | 7 |          8           | 9 |
 *    +---+----------------------+---+
 *  When changing this objects width and/or height:
 *     areas 1 3 7 and 9 will remain unscaled.
 *     areas 2 and 8 will be stretched horizontally
 *     areas 4 and 6 will be stretched vertically
 *     area 5 will be stretched both horizontally and vertically
 * </pre>
 * @example
 * ```ts
 * // Create a basic nine-slice sprite
 * const button = new NineSliceSprite({
 *     texture: Texture.from('button.png'),
 *     leftWidth: 20, // Left border (A)
 *     rightWidth: 20, // Right border (B)
 *     topHeight: 20, // Top border (C)
 *     bottomHeight: 20, // Bottom border (D)
 *     width: 100, // Initial width
 *     height: 50, // Initial height
 *     anchor: 0.5, // Center anchor point
 * });
 * ```
 * @see {@link NineSliceSprite} For the main sprite class
 * @see {@link Texture#defaultBorders} For texture-level border settings
 * @category scene
 * @standard
 */
export interface NineSliceSpriteOptions extends PixiMixins.NineSliceSpriteOptions, ViewContainerOptions {
    /**
     * The texture to use on the NineSliceSprite.
     * ```ts
     * // Create a sprite with a texture
     * const sprite = new NineSliceSprite({
     *     texture: Texture.from('path/to/image.png')
     * });
     * // Update the texture later
     * sprite.texture = Texture.from('path/to/another-image.png');
     * ```
     * @default Texture.EMPTY
     */
    texture: Texture;
    /**
     * Width of the left vertical bar (A).
     * Controls the size of the left edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., leftWidth: 20 });
     * sprite.leftWidth = 20; // Set left border width
     * ```
     * @default 10
     */
    leftWidth?: number;
    /**
     * Height of the top horizontal bar (C).
     * Controls the size of the top edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., topHeight: 20 });
     * sprite.topHeight = 20; // Set top border height
     * ```
     * @default 10
     */
    topHeight?: number;
    /**
     * Width of the right vertical bar (B).
     * Controls the size of the right edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., rightWidth: 20 });
     * sprite.rightWidth = 20; // Set right border width
     * ```
     * @default 10
     */
    rightWidth?: number;
    /**
     * Height of the bottom horizontal bar (D).
     * Controls the size of the bottom edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., bottomHeight: 20 });
     * sprite.bottomHeight = 20; // Set bottom border height
     * ```
     * @default 10
     */
    bottomHeight?: number;
    /**
     * Width of the NineSliceSprite.
     * Modifies the vertices directly rather than UV coordinates
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., width: 200 });
     * sprite.width = 200; // Set the width of the sprite
     * ```
     * @default 100
     */
    width?: number;
    /**
     * Height of the NineSliceSprite.
     * Modifies the vertices directly rather than UV coordinates
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., height: 100 });
     * sprite.height = 100; // Set the height of the sprite
     * ```
     * @default 100
     */
    height?: number;
    /**
     * Whether to round the x/y position to whole pixels
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., roundPixels: true });
     * ```
     * @default false
     */
    roundPixels?: boolean;
    /**
     * The anchor point of the NineSliceSprite (0-1 range)
     *
     * Controls the origin point for rotation, scaling, and positioning.
     * Can be a number for uniform anchor or a PointData for separate x/y values.
     * @default 0
     * @example
     * ```ts
     * // Centered anchor
     * const sprite = new NineSliceSprite({ ..., anchor: 0.5 });
     * sprite.anchor = 0.5;
     * // Separate x/y anchor
     * sprite.anchor = { x: 0.5, y: 0.5 };
     * // Right-aligned anchor
     * sprite.anchor = { x: 1, y: 0 };
     * // Update anchor directly
     * sprite.anchor.set(0.5, 0.5);
     * ```
     */
    anchor?: PointData | number;
}
export interface NineSliceSprite extends PixiMixins.NineSliceSprite, ViewContainer<NineSliceSpriteGpuData> {
}
/**
 * The NineSliceSprite allows you to stretch a texture using 9-slice scaling. The corners will remain unscaled (useful
 * for buttons with rounded corners for example) and the other areas will be scaled horizontally and or vertically
 *
 * <pre>
 *      A                          B
 *    +---+----------------------+---+
 *  C | 1 |          2           | 3 |
 *    +---+----------------------+---+
 *    |   |                      |   |
 *    | 4 |          5           | 6 |
 *    |   |                      |   |
 *    +---+----------------------+---+
 *  D | 7 |          8           | 9 |
 *    +---+----------------------+---+
 *  When changing this objects width and/or height:
 *     areas 1 3 7 and 9 will remain unscaled.
 *     areas 2 and 8 will be stretched horizontally
 *     areas 4 and 6 will be stretched vertically
 *     area 5 will be stretched both horizontally and vertically
 * </pre>
 * @example
 * ```ts
 * import { NineSliceSprite, Texture } from 'pixi.js';
 *
 * const plane9 = new NineSliceSprite({
 *   texture: Texture.from('BoxWithRoundedCorners.png'),
 *   leftWidth: 15,
 *   topHeight: 15,
 *   rightWidth: 15,
 *   bottomHeight: 15,
 *   width: 200,
 *   height: 100,
 * });
 * ```
 * @category scene
 * @standard
 */
export declare class NineSliceSprite extends ViewContainer<NineSliceSpriteGpuData> implements View {
    /**
     * The default options used to override initial values of any options passed in the constructor.
     * These values are used as fallbacks when specific options are not provided.
     * @example
     * ```ts
     * // Override default options globally
     * NineSliceSprite.defaultOptions.texture = Texture.from('defaultButton.png');
     * // Create sprite with default texture
     * const sprite = new NineSliceSprite({...});
     * // sprite will use 'defaultButton.png' as its texture
     *
     * // Reset to empty texture
     * NineSliceSprite.defaultOptions.texture = Texture.EMPTY;
     * ```
     * @type {NineSliceSpriteOptions}
     * @see {@link NineSliceSpriteOptions} For all available options
     * @see {@link Texture#defaultBorders} For texture-level border settings
     */
    static defaultOptions: NineSliceSpriteOptions;
    /** @internal */
    readonly renderPipeId: string;
    /** @internal */
    _texture: Texture;
    /** @internal */
    _anchor: ObservablePoint;
    /** @internal */
    batched: boolean;
    private _leftWidth;
    private _topHeight;
    private _rightWidth;
    private _bottomHeight;
    private _width;
    private _height;
    constructor(options: NineSliceSpriteOptions | Texture);
    /**
     * The anchor sets the origin point of the sprite. The default value is taken from the {@link Texture}
     * and passed to the constructor.
     *
     * - The default is `(0,0)`, this means the sprite's origin is the top left.
     * - Setting the anchor to `(0.5,0.5)` means the sprite's origin is centered.
     * - Setting the anchor to `(1,1)` would mean the sprite's origin point will be the bottom right corner.
     *
     * If you pass only single parameter, it will set both x and y to the same value as shown in the example below.
     * @example
     * ```ts
     * // Center the anchor point
     * sprite.anchor = 0.5; // Sets both x and y to 0.5
     * sprite.position.set(400, 300); // Sprite will be centered at this position
     *
     * // Set specific x/y anchor points
     * sprite.anchor = {
     *     x: 1, // Right edge
     *     y: 0  // Top edge
     * };
     *
     * // Using individual coordinates
     * sprite.anchor.set(0.5, 1); // Center-bottom
     *
     * // For rotation around center
     * sprite.anchor.set(0.5);
     * sprite.rotation = Math.PI / 4; // 45 degrees around center
     *
     * // For scaling from center
     * sprite.anchor.set(0.5);
     * sprite.scale.set(2); // Scales from center point
     * ```
     */
    get anchor(): ObservablePoint;
    set anchor(value: PointData | number);
    /**
     * The width of the NineSliceSprite, setting this will actually modify the vertices and UV's of this plane.
     * The width affects how the middle sections are scaled.
     * @example
     * ```ts
     * // Create a nine-slice sprite with fixed width
     * const panel = new NineSliceSprite({
     *     texture: Texture.from('panel.png'),
     *     width: 200  // Sets initial width
     * });
     *
     * // Adjust width dynamically
     * panel.width = 300;  // Stretches middle sections
     * ```
     * @see {@link NineSliceSprite#setSize} For setting both width and height efficiently
     * @see {@link NineSliceSprite#height} For setting height
     */
    get width(): number;
    set width(value: number);
    /**
     * The height of the NineSliceSprite, setting this will actually modify the vertices and UV's of this plane.
     * The height affects how the middle sections are scaled.
     * @example
     * ```ts
     * // Create a nine-slice sprite with fixed height
     * const panel = new NineSliceSprite({
     *     texture: Texture.from('panel.png'),
     *     height: 150  // Sets initial height
     * });
     *
     * // Adjust height dynamically
     * panel.height = 200;  // Stretches middle sections
     *
     * // Create responsive UI element
     * const dialog = new NineSliceSprite({
     *     texture: Texture.from('dialog.png'),
     *     topHeight: 30,
     *     bottomHeight: 30,
     *     height: parent.height * 0.5  // 50% of parent height
     * });
     * ```
     * @see {@link NineSliceSprite#setSize} For setting both width and height efficiently
     * @see {@link NineSliceSprite#width} For setting width
     */
    get height(): number;
    set height(value: number);
    /**
     * Sets the size of the NineSliceSprite to the specified width and height.
     * This method directly modifies the vertices and UV coordinates of the sprite.
     *
     * Using this is more efficient than setting width and height separately as it only triggers one update.
     * @example
     * ```ts
     * // Set to specific dimensions
     * panel.setSize(300, 200); // Width: 300, Height: 200
     *
     * // Set uniform size
     * panel.setSize(200); // Makes a square 200x200
     *
     * // Set size using object
     * panel.setSize({
     *     width: 400,
     *     height: 300
     * });
     * ```
     * @param value - This can be either a number or a Size object with width/height properties
     * @param height - The height to set. Defaults to the value of `width` if not provided
     * @see {@link NineSliceSprite#width} For setting width only
     * @see {@link NineSliceSprite#height} For setting height only
     */
    setSize(value: number | Optional<Size, 'height'>, height?: number): void;
    /**
     * Retrieves the size of the NineSliceSprite as a [Size]{@link Size} object.
     * This method is more efficient than getting width and height separately.
     * @example
     * ```ts
     * // Get basic size
     * const size = panel.getSize();
     * console.log(`Size: ${size.width}x${size.height}`);
     *
     * // Reuse existing size object
     * const reuseSize = { width: 0, height: 0 };
     * panel.getSize(reuseSize);
     * ```
     * @param out - Optional object to store the size in, to avoid allocating a new object
     * @returns The size of the NineSliceSprite
     * @see {@link NineSliceSprite#width} For getting just the width
     * @see {@link NineSliceSprite#height} For getting just the height
     * @see {@link NineSliceSprite#setSize} For setting both width and height efficiently
     */
    getSize(out?: Size): Size;
    /**
     * Width of the left vertical bar (A).
     * Controls the size of the left edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., leftWidth: 20 });
     * sprite.leftWidth = 20; // Set left border width
     * ```
     * @default 10
     */
    get leftWidth(): number;
    set leftWidth(value: number);
    /**
     * Height of the top horizontal bar (C).
     * Controls the size of the top edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., topHeight: 20 });
     * sprite.topHeight = 20; // Set top border height
     * ```
     * @default 10
     */
    get topHeight(): number;
    set topHeight(value: number);
    /**
     * Width of the right vertical bar (B).
     * Controls the size of the right edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., rightWidth: 20 });
     * sprite.rightWidth = 20; // Set right border width
     * ```
     * @default 10
     */
    get rightWidth(): number;
    set rightWidth(value: number);
    /**
     * Height of the bottom horizontal bar (D).
     * Controls the size of the bottom edge that remains unscaled
     * @example
     * ```ts
     * const sprite = new NineSliceSprite({ ..., bottomHeight: 20 });
     * sprite.bottomHeight = 20; // Set bottom border height
     * ```
     * @default 10
     */
    get bottomHeight(): number;
    set bottomHeight(value: number);
    /**
     * The texture to use on the NineSliceSprite.
     * ```ts
     * // Create a sprite with a texture
     * const sprite = new NineSliceSprite({
     *     texture: Texture.from('path/to/image.png')
     * });
     * // Update the texture later
     * sprite.texture = Texture.from('path/to/another-image.png');
     * ```
     * @default Texture.EMPTY
     */
    get texture(): Texture;
    set texture(value: Texture);
    /**
     * The original width of the texture before any nine-slice scaling.
     * This is the width of the source texture used to create the nine-slice sprite.
     * @example
     * ```ts
     * // Get original dimensions
     * console.log(`Original size: ${sprite.originalWidth}x${sprite.originalHeight}`);
     *
     * // Use for relative scaling
     * sprite.width = sprite.originalWidth * 2; // Double the original width
     *
     * // Reset to original size
     * sprite.setSize(sprite.originalWidth, sprite.originalHeight);
     * ```
     * @readonly
     * @see {@link NineSliceSprite#width} For the current displayed width
     * @see {@link Texture#width} For direct texture width access
     * @returns The original width of the texture
     */
    get originalWidth(): number;
    /**
     * The original height of the texture before any nine-slice scaling.
     * This is the height of the source texture used to create the nine-slice sprite.
     * @example
     * ```ts
     * // Get original dimensions
     * console.log(`Original size: ${sprite.originalWidth}x${sprite.originalHeight}`);
     *
     * // Use for relative scaling
     * sprite.height = sprite.originalHeight * 2; // Double the original height
     *
     * // Reset to original size
     * sprite.setSize(sprite.originalWidth, sprite.originalHeight);
     * ```
     * @readonly
     * @see {@link NineSliceSprite#height} For the current displayed height
     * @see {@link Texture#height} For direct texture height access
     * @returns The original height of the texture
     */
    get originalHeight(): number;
    /**
     * The trim rectangle of the underlying texture, or `null` if the texture is not trimmed.
     * This is forwarded to the {@link NineSliceGeometry} so that UV coordinates are clamped
     * to the visible pixel region, preventing transparent atlas padding from bleeding into
     * the rendered sprite corners.
     * @readonly
     * @internal
     */
    get trim(): import("../..").Rectangle;
    /**
     * Destroys this sprite renderable and optionally its texture.
     * @param options - Options parameter. A boolean will act as if all options
     *  have been set to that value
     * @example
     * nineSliceSprite.destroy();
     * nineSliceSprite.destroy(true);
     * nineSliceSprite.destroy({ texture: true, textureSource: true });
     */
    destroy(options?: DestroyOptions): void;
    /** @private */
    protected updateBounds(): void;
}
/**
 * Please use the {@link NineSliceSprite} class instead.
 * The NineSlicePlane is deprecated and will be removed in future versions.
 * @deprecated since 8.0.0
 * @category scene
 */
export declare class NineSlicePlane extends NineSliceSprite {
    constructor(options: NineSliceSpriteOptions | Texture);
    /** @deprecated since 8.0.0 */
    constructor(texture: Texture, leftWidth: number, topHeight: number, rightWidth: number, bottomHeight: number);
}
