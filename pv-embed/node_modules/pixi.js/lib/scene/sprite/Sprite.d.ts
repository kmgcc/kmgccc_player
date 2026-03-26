import { ObservablePoint } from '../../maths/point/ObservablePoint';
import { Texture } from '../../rendering/renderers/shared/texture/Texture';
import { ViewContainer, type ViewContainerOptions } from '../view/ViewContainer';
import { type BatchableSprite } from './BatchableSprite';
import type { Size } from '../../maths/misc/Size';
import type { PointData } from '../../maths/point/PointData';
import type { TextureSourceLike } from '../../rendering/renderers/shared/texture/Texture';
import type { BoundsData } from '../container/bounds/Bounds';
import type { Optional } from '../container/container-mixins/measureMixin';
import type { DestroyOptions } from '../container/destroyTypes';
/**
 * Options for configuring a Sprite instance. Defines the texture, anchor point, and rendering behavior.
 * @example
 * ```ts
 * // Create a basic sprite with texture
 * const sprite = new Sprite({
 *     texture: Texture.from('sprite.png')
 * });
 *
 * // Create a centered sprite with rounded position
 * const centeredSprite = new Sprite({
 *     texture: Texture.from('centered.png'),
 *     anchor: 0.5,        // Center point
 *     roundPixels: true,  // Crisp rendering
 *     x: 100,            // Position from ViewContainerOptions
 *     y: 100
 * });
 *
 * // Create a sprite with specific anchor points
 * const anchoredSprite = new Sprite({
 *     texture: Texture.from('corner.png'),
 *     anchor: {
 *         x: 1,  // Right-aligned
 *         y: 0   // Top-aligned
 *     }
 * });
 * ```
 * @extends ViewContainerOptions
 * @category scene
 * @standard
 * @noInheritDoc
 */
export interface SpriteOptions extends PixiMixins.SpriteOptions, ViewContainerOptions {
    /**
     * The texture to use for the sprite. If not provided, uses Texture.EMPTY
     * @default Texture.EMPTY
     * @example
     * ```ts
     * // Create a sprite with a texture
     * const sprite = new Sprite({
     *     texture: Texture.from('path/to/image.png')
     * });
     * // Update the texture later
     * sprite.texture = Texture.from('path/to/another-image.png');
     * ```
     */
    texture?: Texture;
    /**
     * The anchor point of the sprite (0-1 range).
     * Controls the origin point for rotation, scaling, and positioning.
     * Can be a number for uniform anchor or a PointData for separate x/y values.
     * @default 0
     * @example
     * ```ts
     * // Centered anchor
     * anchor: 0.5
     * // Separate x/y anchor
     * anchor: { x: 0.5, y: 0.5 }
     * // Right-aligned anchor
     * anchor: { x: 1, y: 0 }
     * ```
     */
    anchor?: PointData | number;
    /**
     * Whether or not to round the x/y position to whole pixels.
     * Useful for crisp pixel art style rendering.
     * @default false
     * @example
     * ```ts
     * const sprite = new Sprite({
     *     texture: Texture.from('sprite.png'),
     *     roundPixels: true // Ensures crisp rendering
     * });
     * ```
     */
    roundPixels?: boolean;
}
export interface Sprite extends PixiMixins.Sprite, ViewContainer<BatchableSprite> {
}
/**
 * The Sprite object is one of the most important objects in PixiJS. It is a
 * drawing item that can be added to a scene and rendered to the screen.
 * Sprites can display images, handle input events, and be transformed in various ways.
 * @example
 * ```ts
 * // Create a sprite directly from an image path
 * const sprite = Sprite.from('assets/image.png');
 * sprite.position.set(100, 100);
 * app.stage.addChild(sprite);
 *
 * // Create from a spritesheet (more efficient)
 * const sheet = await Assets.load('assets/spritesheet.json');
 * const sprite = new Sprite(sheet.textures['image.png']);
 *
 * // Create with specific options
 * const configuredSprite = new Sprite({
 *     texture: Texture.from('sprite.png'),
 *     anchor: 0.5,           // Center anchor point
 *     position: { x: 100, y: 100 },
 *     scale: { x: 2, y: 2 }, // Double size
 *     rotation: Math.PI / 4   // 45 degrees
 * });
 *
 * // Animate sprite properties
 * app.ticker.add(() => {
 *     sprite.rotation += 0.1;      // Rotate
 *     sprite.scale.x = Math.sin(performance.now() / 1000) + 1; // Pulse scale
 * });
 * ```
 * @category scene
 * @standard
 * @see {@link SpriteOptions} For configuration options
 * @see {@link Texture} For texture management
 * @see {@link Assets} For asset loading
 */
export declare class Sprite extends ViewContainer<BatchableSprite> {
    /**
     * Creates a new sprite based on a source texture, image, video, or canvas element.
     * This is a convenience method that automatically creates and manages textures.
     * @example
     * ```ts
     * // Create from path or URL
     * const sprite = Sprite.from('assets/image.png');
     *
     * // Create from existing texture
     * const sprite = Sprite.from(texture);
     *
     * // Create from canvas
     * const canvas = document.createElement('canvas');
     * const sprite = Sprite.from(canvas, true); // Skip caching new texture
     * ```
     * @param source - The source to create the sprite from. Can be a path to an image, a texture,
     * or any valid texture source (canvas, video, etc.)
     * @param skipCache - Whether to skip adding to the texture cache when creating a new texture
     * @returns A new sprite based on the source
     * @see {@link Texture.from} For texture creation details
     * @see {@link Assets} For asset loading and management
     */
    static from(source: Texture | TextureSourceLike, skipCache?: boolean): Sprite;
    /** @internal */
    readonly renderPipeId: string;
    /** @internal */
    batched: boolean;
    /** @internal */
    readonly _anchor: ObservablePoint;
    /** @internal */
    _texture: Texture;
    private readonly _visualBounds;
    private _width;
    private _height;
    /**
     * @param options - The options for creating the sprite.
     */
    constructor(options?: SpriteOptions | Texture);
    set texture(value: Texture);
    /**
     * The texture that is displayed by the sprite. When changed, automatically updates
     * the sprite dimensions and manages texture event listeners.
     * @example
     * ```ts
     * // Create sprite with texture
     * const sprite = new Sprite({
     *     texture: Texture.from('sprite.png')
     * });
     *
     * // Update texture
     * sprite.texture = Texture.from('newSprite.png');
     *
     * // Use texture from spritesheet
     * const sheet = await Assets.load('spritesheet.json');
     * sprite.texture = sheet.textures['frame1.png'];
     *
     * // Reset to empty texture
     * sprite.texture = Texture.EMPTY;
     * ```
     * @see {@link Texture} For texture creation and management
     * @see {@link Assets} For asset loading
     */
    get texture(): Texture;
    /**
     * The bounds of the sprite, taking into account the texture's trim area.
     * @example
     * ```ts
     * const texture = new Texture({
     *     source: new TextureSource({ width: 300, height: 300 }),
     *     frame: new Rectangle(196, 66, 58, 56),
     *     trim: new Rectangle(4, 4, 58, 56),
     *     orig: new Rectangle(0, 0, 64, 64),
     *     rotate: 2,
     * });
     * const sprite = new Sprite(texture);
     * const visualBounds = sprite.visualBounds;
     * // console.log(visualBounds); // { minX: -4, maxX: 62, minY: -4, maxY: 60 }
     */
    get visualBounds(): BoundsData;
    /**
     * @deprecated
     * @ignore
     */
    get sourceBounds(): BoundsData;
    /** @private */
    protected updateBounds(): void;
    /**
     * Destroys this sprite renderable and optionally its texture.
     * @param options - Options parameter. A boolean will act as if all options
     *  have been set to that value
     * @example
     * sprite.destroy();
     * sprite.destroy(true);
     * sprite.destroy({ texture: true, textureSource: true });
     */
    destroy(options?: DestroyOptions): void;
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
     * The width of the sprite, setting this will actually modify the scale to achieve the value set.
     * @example
     * ```ts
     * // Set width directly
     * sprite.width = 200;
     * console.log(sprite.scale.x); // Scale adjusted to match width
     *
     * // Set width while preserving aspect ratio
     * const ratio = sprite.height / sprite.width;
     * sprite.width = 300;
     * sprite.height = 300 * ratio;
     *
     * // For better performance when setting both width and height
     * sprite.setSize(300, 400); // Avoids recalculating bounds twice
     *
     * // Reset to original texture size
     * sprite.width = sprite.texture.orig.width;
     * ```
     */
    get width(): number;
    set width(value: number);
    /**
     * The height of the sprite, setting this will actually modify the scale to achieve the value set.
     * @example
     * ```ts
     * // Set height directly
     * sprite.height = 150;
     * console.log(sprite.scale.y); // Scale adjusted to match height
     *
     * // Set height while preserving aspect ratio
     * const ratio = sprite.width / sprite.height;
     * sprite.height = 200;
     * sprite.width = 200 * ratio;
     *
     * // For better performance when setting both width and height
     * sprite.setSize(300, 400); // Avoids recalculating bounds twice
     *
     * // Reset to original texture size
     * sprite.height = sprite.texture.orig.height;
     * ```
     */
    get height(): number;
    set height(value: number);
    /**
     * Retrieves the size of the Sprite as a [Size]{@link Size} object based on the texture dimensions and scale.
     * This is faster than getting width and height separately as it only calculates the bounds once.
     * @example
     * ```ts
     * // Basic size retrieval
     * const sprite = new Sprite(Texture.from('sprite.png'));
     * const size = sprite.getSize();
     * console.log(`Size: ${size.width}x${size.height}`);
     *
     * // Reuse existing size object
     * const reuseSize = { width: 0, height: 0 };
     * sprite.getSize(reuseSize);
     * ```
     * @param out - Optional object to store the size in, to avoid allocating a new object
     * @returns The size of the Sprite
     * @see {@link Sprite#width} For getting just the width
     * @see {@link Sprite#height} For getting just the height
     * @see {@link Sprite#setSize} For setting both width and height
     */
    getSize(out?: Size): Size;
    /**
     * Sets the size of the Sprite to the specified width and height.
     * This is faster than setting width and height separately as it only recalculates bounds once.
     * @example
     * ```ts
     * // Basic size setting
     * const sprite = new Sprite(Texture.from('sprite.png'));
     * sprite.setSize(100, 200); // Width: 100, Height: 200
     *
     * // Set uniform size
     * sprite.setSize(100); // Sets both width and height to 100
     *
     * // Set size with object
     * sprite.setSize({
     *     width: 200,
     *     height: 300
     * });
     *
     * // Reset to texture size
     * sprite.setSize(
     *     sprite.texture.orig.width,
     *     sprite.texture.orig.height
     * );
     * ```
     * @param value - This can be either a number or a {@link Size} object
     * @param height - The height to set. Defaults to the value of `width` if not provided
     * @see {@link Sprite#width} For setting width only
     * @see {@link Sprite#height} For setting height only
     * @see {@link Sprite#texture} For the source dimensions
     */
    setSize(value: number | Optional<Size, 'height'>, height?: number): void;
}
