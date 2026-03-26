import { type ImageLike } from '../../../environment/ImageLike';
import type { CanvasAndContext } from '../../../rendering/renderers/shared/texture/CanvasPool';
/**
 * This function converts an image to a canvas, and returns the canvas.
 * It is used to convert images to canvases to work around a CORS issue where WebGPU cannot
 * upload an SVGImage to a texture.
 *
 * It uses the CanvasPool to get an optimal canvas and context, and then draws the image onto it.
 * Remember to return this canvas is immediately to the CanvasPool for reuse when you are done with it.
 * (eg upload it to the GPU!)
 * @param image - The image to convert to a canvas.
 * @param resolution - The resolution of the canvas.
 * @internal
 */
export declare function getTemporaryCanvasFromImage(image: ImageLike, resolution: number): CanvasAndContext;
