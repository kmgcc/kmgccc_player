import { Rectangle } from '../../maths/shapes/Rectangle';
import type { ICanvas } from '../../environment/canvas/ICanvas';
/** @internal */
export interface GetCanvasBoundingBoxOptions {
    /** The canvas to measure */
    canvas: ICanvas;
    /** Optional. The width to analyze (defaults to canvas.width) */
    width?: number;
    /** Optional. The height to analyze (defaults to canvas.height) */
    height?: number;
    /**
     * Optional. The resolution at which to analyze the canvas, between 0-1.
     * Lower values improve performance for large canvases but may be less precise.
     * Default is 1 (full resolution).
     */
    resolution?: number;
    /** Optional. The rectangle to store the result in. */
    output?: Rectangle;
}
/**
 * Measures the bounding box of a canvas's visible (non-transparent) pixels.
 *
 * This function analyzes the alpha channel of the canvas pixels to find the smallest
 * rectangle containing all non-transparent pixels. It's useful for optimizing sprite
 * rendering by trimming transparent borders.
 *
 * Uses an internal canvas with `willReadFrequently: true` for efficient pixel data access.
 * This internal canvas is reused between calls for better performance.
 * @example
 * ```typescript
 * // Basic usage - get trim bounds at full resolution
 * const bounds = getCanvasBoundingBox({ canvas: myCanvas });
 * console.log(bounds); // Rectangle{x: 10, y: 5, width: 100, height: 200}
 * // Optimized for performance with lower resolution scanning
 * const fastBounds = getCanvasBoundingBox({
 *     canvas: largeCanvas,
 *     width: largeCanvas.width,
 *     height: largeCanvas.height,
 *     resolution: 0.5
 * });
 * // Resolution of 0.5 means scanning at half size, much faster for large canvases
 *
 * // Using custom dimensions - only analyze part of the canvas
 * const partialBounds = getCanvasBoundingBox({ canvas: myCanvas, width: 100, height: 100 });
 * // Only analyzes a 100x100 region starting from top-left
 * ```
 * @param options - The options for measuring the bounding box, including the canvas to measure.
 * @returns The bounding box as a Rectangle containing the visible content.
 *          Returns Rectangle.EMPTY if the canvas is completely transparent.
 * @internal
 */
export declare function getCanvasBoundingBox(options: GetCanvasBoundingBoxOptions): Rectangle;
/**
 * @param canvas
 * @param resolution
 * @internal
 * @deprecated since 8.10.0
 */
export declare function getCanvasBoundingBox(canvas: ICanvas, resolution?: number): Rectangle;
