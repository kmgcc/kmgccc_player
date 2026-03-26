import type { ICanvasRenderingContext2D } from '../../../../environment/canvas/ICanvasRenderingContext2D';
import type { ConvertedFillStyle } from '../../../graphics/shared/FillTypes';
import type { CanvasTextMetrics } from '../CanvasTextMetrics';
/**
 * Converts a PixiJS fill style into a Canvas-compatible fill style.
 * Handles solid colors, textures, patterns, and gradients.
 * @param fillStyle - The PixiJS fill style to convert
 * @param context - The canvas rendering context
 * @param textMetrics - Metrics about the text being rendered
 * @param padding - Padding to add to the text metrics (used to ensure that the gradient accommodates the stroke width)
 * @param offsetX - X offset for gradient positioning (used for tagged text runs)
 * @param offsetY - Y offset for gradient positioning (used for tagged text runs)
 * @returns Canvas-compatible fill style (string, CanvasGradient, or CanvasPattern)
 * @internal
 */
export declare function getCanvasFillStyle(fillStyle: ConvertedFillStyle, context: ICanvasRenderingContext2D, textMetrics?: CanvasTextMetrics, padding?: number, offsetX?: number, offsetY?: number): string | CanvasGradient | CanvasPattern;
