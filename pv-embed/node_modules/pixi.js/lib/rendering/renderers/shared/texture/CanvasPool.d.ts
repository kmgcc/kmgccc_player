import type { ICanvas, ICanvasRenderingContext2DSettings } from '../../../../environment/canvas/ICanvas';
import type { ICanvasRenderingContext2D } from '../../../../environment/canvas/ICanvasRenderingContext2D';
/**
 * A utility type that represents a canvas and its rendering context.
 * @category rendering
 * @internal
 */
export interface CanvasAndContext {
    /** The canvas element. */
    canvas: ICanvas;
    /** The rendering context of the canvas. */
    context: ICanvasRenderingContext2D;
}
/**
 * CanvasPool is a utility class that manages a pool of reusable canvas elements
 * @category rendering
 * @internal
 */
export declare class CanvasPoolClass {
    canvasOptions: ICanvasRenderingContext2DSettings;
    /**
     * Allow renderTextures of the same size as screen, not just pow2
     *
     * Automatically sets to true after `setScreenSize`
     * @default false
     */
    enableFullScreen: boolean;
    private _canvasPool;
    constructor(canvasOptions?: ICanvasRenderingContext2DSettings);
    /**
     * Creates texture with params that were specified in pool constructor.
     * @param pixelWidth - Width of texture in pixels.
     * @param pixelHeight - Height of texture in pixels.
     */
    private _createCanvasAndContext;
    /**
     * Gets a Power-of-Two render texture or fullScreen texture
     * @param minWidth - The minimum width of the render texture.
     * @param minHeight - The minimum height of the render texture.
     * @param resolution - The resolution of the render texture.
     * @returns The new render texture.
     */
    getOptimalCanvasAndContext(minWidth: number, minHeight: number, resolution?: number): CanvasAndContext;
    /**
     * Place a render texture back into the pool.
     * @param canvasAndContext
     */
    returnCanvasAndContext(canvasAndContext: CanvasAndContext): void;
    clear(): void;
}
/**
 * CanvasPool is a utility class that manages a pool of reusable canvas elements
 * @category rendering
 * @internal
 */
export declare const CanvasPool: CanvasPoolClass;
