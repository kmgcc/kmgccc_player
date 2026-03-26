import { type ColorSource } from '../../../../color/Color';
import { ExtensionType } from '../../../../extensions/Extensions';
import { Rectangle } from '../../../../maths/shapes/Rectangle';
import { Container } from '../../../../scene/container/Container';
import { RenderTexture } from '../texture/RenderTexture';
import type { Renderer } from '../../types';
import type { System } from '../system/System';
import type { TextureSourceOptions } from '../texture/sources/TextureSource';
/**
 * Options for generating a texture source.
 * @category rendering
 * @advanced
 * @interface
 */
export type GenerateTextureSourceOptions = Omit<TextureSourceOptions, 'resource' | 'width' | 'height' | 'resolution'>;
/**
 * Options for generating a texture from a container.
 * Used to create reusable textures from display objects, which can improve performance
 * when the same content needs to be rendered multiple times.
 * @example
 * ```ts
 * // Basic texture generation
 * const sprite = new Sprite(texture);
 * const generatedTexture = renderer.generateTexture({
 *     target: sprite
 * });
 *
 * // Generate with custom region and resolution
 * const texture = renderer.generateTexture({
 *     target: container,
 *     frame: new Rectangle(0, 0, 100, 100),
 *     resolution: 2
 * });
 *
 * // Generate with background color and anti-aliasing
 * const highQualityTexture = renderer.generateTexture({
 *     target: graphics,
 *     clearColor: '#ff0000',
 *     antialias: true,
 *     textureSourceOptions: {
 *         scaleMode: 'linear'
 *     }
 * });
 * ```
 * @category rendering
 * @advanced
 */
export type GenerateTextureOptions = {
    /**
     * The container to generate the texture from.
     * This can be any display object like Sprite, Container, or Graphics.
     * @example
     * ```ts
     * const graphics = new Graphics()
     *     .circle(0, 0, 50)
     *     .fill('red');
     *
     * const texture = renderer.generateTexture({
     *     target: graphics
     * });
     * ```
     */
    target: Container;
    /**
     * The region of the container that should be rendered.
     * If not specified, defaults to the local bounds of the container.
     * @example
     * ```ts
     * // Extract only a portion of the container
     * const texture = renderer.generateTexture({
     *     target: container,
     *     frame: new Rectangle(10, 10, 100, 100)
     * });
     * ```
     */
    frame?: Rectangle;
    /**
     * The resolution of the texture being generated.
     * Higher values create sharper textures at the cost of memory.
     * @default renderer.resolution
     * @example
     * ```ts
     * // Generate a high-resolution texture
     * const hiResTexture = renderer.generateTexture({
     *     target: sprite,
     *     resolution: 2 // 2x resolution
     * });
     * ```
     */
    resolution?: number;
    /**
     * The color used to clear the texture before rendering.
     * Can be a hex number, string, or array of numbers.
     * @example
     * ```ts
     * // Clear with red background
     * const texture = renderer.generateTexture({
     *     target: sprite,
     *     clearColor: '#ff0000'
     * });
     *
     * // Clear with semi-transparent black
     * const texture = renderer.generateTexture({
     *     target: sprite,
     *     clearColor: [0, 0, 0, 0.5]
     * });
     * ```
     */
    clearColor?: ColorSource;
    /**
     * Whether to enable anti-aliasing. This may affect performance.
     * @default false
     * @example
     * ```ts
     * // Generate a smooth texture
     * const texture = renderer.generateTexture({
     *     target: graphics,
     *     antialias: true
     * });
     * ```
     */
    antialias?: boolean;
    /**
     * Advanced options for configuring the texture source.
     * Controls texture properties like scale mode and filtering.
     * @advanced
     * @example
     * ```ts
     * const texture = renderer.generateTexture({
     *     target: sprite,
     *     textureSourceOptions: {
     *         scaleMode: 'linear',
     *     }
     * });
     * ```
     */
    textureSourceOptions?: GenerateTextureSourceOptions;
};
/**
 * System that manages the generation of textures from display objects in the renderer.
 * This system is responsible for creating reusable textures from containers, sprites, and other display objects.
 * Available through `renderer.textureGenerator`.
 * @example
 * ```ts
 * import { Application, Sprite, Graphics } from 'pixi.js';
 *
 * const app = new Application();
 * await app.init();
 *
 * // Create a complex display object
 * const container = new Container();
 *
 * const graphics = new Graphics()
 *     .circle(0, 0, 50)
 *     .fill('red');
 *
 * const sprite = new Sprite(texture);
 * sprite.x = 100;
 *
 * container.addChild(graphics, sprite);
 *
 * // Generate a texture from the container
 * const generatedTexture = app.renderer.textureGenerator.generateTexture({
 *     target: container,
 *     resolution: 2,
 *     antialias: true
 * });
 *
 * // Use the generated texture
 * const newSprite = new Sprite(generatedTexture);
 * app.stage.addChild(newSprite);
 *
 * // Clean up when done
 * generatedTexture.destroy(true);
 * ```
 *
 * Features:
 * - Convert any display object to a texture
 * - Support for custom regions and resolutions
 * - Anti-aliasing support
 * - Background color configuration
 * - Texture source options customization
 *
 * Common Use Cases:
 * - Creating texture atlases dynamically
 * - Caching complex container content
 * - Generating thumbnails
 * - Creating reusable textures from rendered content
 *
 * Performance Considerations:
 * - Generating textures is relatively expensive
 * - Cache results when possible
 * - Be mindful of resolution and size
 * - Clean up unused textures
 * @see {@link GenerateTextureOptions} For detailed texture generation options
 * @see {@link AbstractRenderer.generateTexture} For the main renderer method
 * @see {@link RenderTexture} For the resulting texture type
 * @category rendering
 * @standard
 */
export declare class GenerateTextureSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "textureGenerator";
    };
    private readonly _renderer;
    constructor(renderer: Renderer);
    /**
     * Creates a texture from a display object that can be used for creating sprites and other textures.
     * This is particularly useful for optimizing performance when a complex container needs to be reused.
     * @param options - Generate texture options or a container to convert to texture
     * @returns A new RenderTexture containing the rendered display object
     * @example
     * ```ts
     * // Basic usage with a container
     * const container = new Container();
     * container.addChild(
     *     new Graphics()
     *         .circle(0, 0, 50)
     *         .fill('red')
     * );
     *
     * const texture = renderer.textureGenerator.generateTexture(container);
     *
     * // Advanced usage with options
     * const texture = renderer.textureGenerator.generateTexture({
     *     target: container,
     *     frame: new Rectangle(0, 0, 100, 100), // Specific region
     *     resolution: 2,                        // High DPI
     *     clearColor: '#ff0000',               // Red background
     *     antialias: true                      // Smooth edges
     * });
     *
     * // Create a sprite from the generated texture
     * const sprite = new Sprite(texture);
     *
     * // Clean up when done
     * texture.destroy(true);
     * ```
     * @see {@link GenerateTextureOptions} For detailed texture generation options
     * @see {@link RenderTexture} For the type of texture created
     * @category rendering
     */
    generateTexture(options: GenerateTextureOptions | Container): RenderTexture;
    destroy(): void;
}
