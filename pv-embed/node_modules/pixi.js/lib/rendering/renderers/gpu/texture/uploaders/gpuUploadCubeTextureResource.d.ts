import type { CubeTextureSource } from '../../../shared/texture/sources/CubeTextureSource';
import type { GpuTextureUploader } from './GpuTextureUploader';
/**
 * Creates a cube uploader that delegates to the given uploader registry.
 * @param uploaders - Uploader registry keyed by `uploadMethodId` (must include `image`).
 * @internal
 */
export declare function createGpuUploadCubeTextureResource(uploaders: Record<string, GpuTextureUploader> & {
    image: GpuTextureUploader;
}): GpuTextureUploader<CubeTextureSource>;
