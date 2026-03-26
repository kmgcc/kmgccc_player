import { type ImageLike } from '../../../environment/ImageLike';
/**
 * This function loads an SVG image into an IImage element.
 * The image can then be uploaded as texture to the GPU.
 * iOS has a bug where embedded fonts are not available immediately after the image loads,
 * so we wait an arbitrary amount of time before resolving the promise.
 * @param image - The image to load the SVG into
 * @param url - The url to load the SVG from
 * @param delay - Whether to delay the load
 * @returns - A promise that resolves when the image has loaded
 * @internal
 */
export declare function loadSVGImage(image: ImageLike, url: string, delay: boolean): Promise<void>;
