import { TextureSource } from './TextureSource';
import type { ICanvas } from '../../../../../environment/canvas/ICanvas';
import type { ExtensionMetadata } from '../../../../../extensions/Extensions';
import type { TextureSourceOptions } from './TextureSource';
/**
 * Options for creating a CanvasSource.
 * @category rendering
 * @advanced
 */
export interface CanvasSourceOptions extends TextureSourceOptions<ICanvas> {
    /**
     * Should the canvas be resized to preserve its screen width and height regardless
     * of the resolution of the renderer, this is only supported for HTMLCanvasElement
     * and will be ignored if the canvas is an OffscreenCanvas.
     */
    autoDensity?: boolean;
    /** if true, this canvas will be set up to be transparent where possible */
    transparent?: boolean;
}
/**
 * A texture source that uses a canvas as its resource.
 * It automatically resizes the canvas based on the width, height, and resolution.
 * It also provides a 2D rendering context for drawing.
 * @category rendering
 * @advanced
 */
export declare class CanvasSource extends TextureSource<ICanvas> {
    static extension: ExtensionMetadata;
    uploadMethodId: string;
    autoDensity: boolean;
    transparent: boolean;
    private _context2D;
    constructor(options: CanvasSourceOptions);
    resizeCanvas(): void;
    resize(width?: number, height?: number, resolution?: number): boolean;
    static test(resource: any): resource is ICanvas;
    /**
     * Returns the 2D rendering context for the canvas.
     * Caches the context after creating it.
     * @returns The 2D rendering context of the canvas.
     */
    get context2D(): CanvasRenderingContext2D;
}
