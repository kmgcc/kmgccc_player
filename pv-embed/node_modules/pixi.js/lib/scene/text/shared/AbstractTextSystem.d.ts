import { type CanvasTextOptions, type Text } from '../Text';
import { TextStyle } from '../TextStyle';
import type { System } from '../../../rendering/renderers/shared/system/System';
import type { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import type { Renderer } from '../../../rendering/renderers/types';
/**
 * Base system plugin to the renderer to manage canvas text.
 * @category rendering
 * @advanced
 */
export declare abstract class AbstractTextSystem implements System {
    protected readonly _renderer: Renderer;
    private readonly _retainCanvasContext;
    private readonly _activeTextures;
    constructor(renderer: Renderer, retainCanvasContext: boolean);
    /** @deprecated since 8.0.0 */
    getTexture(text: string, resolution: number, style: TextStyle, textKey: string): Texture;
    /**
     * This is a function that will create a texture from a text string, style and resolution.
     * Useful if you want to make a texture of your text and use if for various pixi things!
     * @param options - The options of the text that will be used to generate the texture.
     * @param options.text - the text to render
     * @param options.style - the style of the text
     * @param options.resolution - the resolution of the texture
     * @returns the newly created texture
     */
    getTexture(options: CanvasTextOptions): Texture;
    /**
     * Returns a texture that was created wit the above `getTexture` function.
     * Handy if you are done with a texture and want to return it to the pool.
     * @param texture - The texture to be returned.
     */
    returnTexture(texture: Texture): void;
    /**
     * Renders text to its canvas, and updates its texture.
     * @deprecated since 8.10.0
     */
    renderTextToCanvas(): void;
    /**
     * Gets or creates a managed texture for a Text object. This method handles texture reuse and reference counting.
     * @param text - The Text object that needs a texture
     * @returns A Texture instance that represents the rendered text
     * @remarks
     * This method performs the following:
     * 1. Sets the appropriate resolution based on auto-resolution settings
     * 2. Checks if a texture already exists for the text's style
     * 3. Creates a new texture if needed or returns an existing one
     * 4. Manages reference counting for texture reuse
     */
    getManagedTexture(text: Text): Texture<import("../../..").TextureSource<any>>;
    /**
     * Decreases the reference count for a texture associated with a text key.
     * When the reference count reaches zero, the texture is returned to the pool.
     * @param textKey - The unique key identifying the text style configuration
     * @remarks
     * This method is crucial for memory management, ensuring textures are properly
     * cleaned up when they are no longer needed by any Text instances.
     */
    decreaseReferenceCount(textKey: string): void;
    /**
     * Gets the current reference count for a texture associated with a text key.
     * @param textKey - The unique key identifying the text style configuration
     * @returns The number of Text instances currently using this texture
     */
    getReferenceCount(textKey: string): number;
    private _increaseReferenceCount;
    /**
     * Applies the specified filters to the given texture.
     *
     * This method takes a texture and a list of filters, applies the filters to the texture,
     * and returns the resulting texture. It also ensures that the alpha mode of the resulting
     * texture is set to 'premultiplied-alpha'.
     * @param {Texture} texture - The texture to which the filters will be applied.
     * @param {Filter[]} filters - The filters to apply to the texture.
     * @returns {Texture} The resulting texture after all filters have been applied.
     */
    private _applyFilters;
    destroy(): void;
}
