import { TextureSource } from './TextureSource';
import type { ExtensionMetadata } from '../../../../../extensions/Extensions';
import type { TypedArray } from '../../buffer/Buffer';
import type { TextureSourceOptions } from './TextureSource';
/**
 * Options for creating a BufferImageSource.
 * @category rendering
 * @advanced
 */
export interface BufferSourceOptions extends TextureSourceOptions<TypedArray | ArrayBuffer> {
    width: number;
    height: number;
}
/**
 * A texture source that uses a TypedArray or ArrayBuffer as its resource.
 * It automatically determines the format based on the type of TypedArray provided.
 * @category rendering
 * @advanced
 */
export declare class BufferImageSource extends TextureSource<TypedArray | ArrayBuffer> {
    static extension: ExtensionMetadata;
    uploadMethodId: string;
    constructor(options: BufferSourceOptions);
    static test(resource: any): resource is TypedArray | ArrayBuffer;
}
