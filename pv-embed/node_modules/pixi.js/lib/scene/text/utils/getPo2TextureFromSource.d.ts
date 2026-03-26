import { type ImageLike } from '../../../environment/ImageLike';
import type { ICanvas } from '../../../environment/canvas/ICanvas';
import type { Texture } from '../../../rendering/renderers/shared/texture/Texture';
/**
 * Takes an image and creates a texture from it, using a power of 2 texture from the texture pool.
 * Remember to return the texture when you don't need it any more!
 * @param image - The image to create a texture from
 * @param width - the frame width of the texture
 * @param height - the frame height of the texture
 * @param resolution - The resolution of the texture
 * @param autoGenerateMipmaps - Whether to generate mipmaps for the texture
 * @returns - The texture
 * @internal
 */
export declare function getPo2TextureFromSource(image: ImageLike | HTMLCanvasElement | ICanvas, width: number, height: number, resolution: number, autoGenerateMipmaps?: boolean): Texture;
