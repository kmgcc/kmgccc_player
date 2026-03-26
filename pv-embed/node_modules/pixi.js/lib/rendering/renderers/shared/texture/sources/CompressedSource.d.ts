import { TextureSource } from './TextureSource';
import type { TextureSourceOptions } from './TextureSource';
/**
 * A texture source that uses a compressed resource, such as an array of Uint8Arrays.
 * It is used for compressed textures that can be uploaded to the GPU.
 * @category rendering
 * @advanced
 */
export declare class CompressedSource extends TextureSource<Uint8Array[]> {
    readonly uploadMethodId = "compressed";
    constructor(options: TextureSourceOptions);
}
