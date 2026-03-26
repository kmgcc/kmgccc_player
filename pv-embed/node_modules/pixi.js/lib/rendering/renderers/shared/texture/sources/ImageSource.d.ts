import { TextureSource } from './TextureSource';
import type { ICanvas } from '../../../../../environment/canvas/ICanvas';
import type { ExtensionMetadata } from '../../../../../extensions/Extensions';
import type { TextureSourceOptions } from './TextureSource';
/**
 * The type of image-like resource that can be used as a texture source.
 *
 * - `ImageBitmap` is used for bitmap images.
 * - `HTMLCanvasElement` and `OffscreenCanvas` are used for canvas elements.
 * - `ICanvas` is an interface for canvas-like objects.
 * - `VideoFrame` is used for video frames.
 * - `HTMLImageElement` is used for HTML image elements.
 * - `HTMLVideoElement` is used for HTML video elements.
 * @category rendering
 * @advanced
 */
export type ImageResource = ImageBitmap | HTMLCanvasElement | OffscreenCanvas | ICanvas | VideoFrame | HTMLImageElement | HTMLVideoElement;
/**
 * A texture source that uses an image-like resource as its resource.
 * It can handle HTMLImageElement, ImageBitmap, VideoFrame, and HTMLVideoElement.
 * It is used for textures that can be uploaded to the GPU.
 * @category rendering
 * @advanced
 */
export declare class ImageSource extends TextureSource<ImageResource> {
    static extension: ExtensionMetadata;
    uploadMethodId: string;
    constructor(options: TextureSourceOptions<ImageResource>);
    static test(resource: any): resource is ImageResource;
}
