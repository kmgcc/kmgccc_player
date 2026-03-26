import { ExtensionType } from '../../../../extensions/Extensions';
import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { System } from '../../shared/system/System';
import type { CanvasGenerator, GetPixelsOutput } from '../../shared/texture/GenerateCanvas';
import type { TextureSource } from '../../shared/texture/sources/TextureSource';
import type { Texture } from '../../shared/texture/Texture';
import type { CanvasRenderer } from '../CanvasRenderer';
/**
 * Texture helper system for CanvasRenderer.
 * @category rendering
 * @advanced
 */
export declare class CanvasTextureSystem implements System, CanvasGenerator {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasSystem];
        readonly name: "texture";
    };
    /**
     * @param renderer - The owning CanvasRenderer.
     */
    constructor(renderer: CanvasRenderer);
    /** Initializes the system (no-op for canvas). */
    init(): void;
    /**
     * Initializes a texture source (no-op for canvas).
     * @param _source - Texture source.
     */
    initSource(_source: TextureSource): void;
    /**
     * Creates a canvas containing the texture's frame.
     * @param texture - Texture to render.
     */
    generateCanvas(texture: Texture): ICanvas;
    /**
     * Reads pixel data from a texture.
     * @param texture - Texture to read.
     */
    getPixels(texture: Texture): GetPixelsOutput;
    /** Destroys the system (no-op for canvas). */
    destroy(): void;
}
