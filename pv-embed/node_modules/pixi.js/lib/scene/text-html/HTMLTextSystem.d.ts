import { ExtensionType } from '../../extensions/Extensions';
import { type Renderer } from '../../rendering/renderers/types';
import type { System } from '../../rendering/renderers/shared/system/System';
import type { Texture } from '../../rendering/renderers/shared/texture/Texture';
import type { HTMLText, HTMLTextOptions } from './HTMLText';
/**
 * System plugin to the renderer to manage HTMLText
 * @category rendering
 * @advanced
 */
export declare class HTMLTextSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "htmlText";
    };
    /**
     * WebGPU has a cors issue when uploading an image that is an SVGImage
     * To get around this we need to create a canvas draw the image to it and upload that instead.
     * Bit of a shame.. but no other work around just yet!
     */
    private readonly _createCanvas;
    private readonly _renderer;
    private readonly _activeTextures;
    constructor(renderer: Renderer);
    /**
     * @param options
     * @deprecated Use getTexturePromise instead
     */
    getTexture(options: HTMLTextOptions): Promise<Texture>;
    /**
     * Increases the reference count for a texture.
     * @param text - The HTMLText instance associated with the texture.
     */
    getManagedTexture(text: HTMLText): Promise<Texture>;
    /**
     * Gets the current reference count for a texture associated with a text key.
     * @param textKey - The unique key identifying the text style configuration
     * @returns The number of Text instances currently using this texture
     */
    getReferenceCount(textKey: string): number;
    private _increaseReferenceCount;
    /**
     * Decreases the reference count for a texture.
     * If the count reaches zero, the texture is cleaned up.
     * @param textKey - The key associated with the HTMLText instance.
     */
    decreaseReferenceCount(textKey: string): void;
    /**
     * Returns a promise that resolves to a texture for the given HTMLText options.
     * @param options - The options for the HTMLText.
     * @returns A promise that resolves to a Texture.
     */
    getTexturePromise(options: HTMLTextOptions): Promise<Texture>;
    private _buildTexturePromise;
    returnTexturePromise(texturePromise: Promise<Texture>): void;
    private _cleanUp;
    destroy(): void;
}
