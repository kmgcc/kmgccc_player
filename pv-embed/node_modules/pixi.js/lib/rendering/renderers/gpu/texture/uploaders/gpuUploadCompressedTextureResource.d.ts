import type { CompressedSource } from '../../../shared/texture/sources/CompressedSource';
import type { GpuTextureUploader } from './GpuTextureUploader';
/** @internal */
export declare const blockDataMap: Record<string, {
    blockBytes: number;
    blockWidth: number;
    blockHeight: number;
}>;
/** @internal */
export declare const gpuUploadCompressedTextureResource: GpuTextureUploader<CompressedSource>;
