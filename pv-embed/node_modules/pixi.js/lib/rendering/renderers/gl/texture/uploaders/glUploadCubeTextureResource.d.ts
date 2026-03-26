import type { GLTextureUploader } from './GLTextureUploader';
/**
 * Creates a cube uploader that delegates to the given uploader registry.
 * This keeps the uploader map owned by the texture system (better discoverability),
 * while allowing cube uploads to reuse the same 2D upload implementations.
 * @param uploaders - Uploader registry keyed by `uploadMethodId` (must include `image`).
 * @internal
 */
export declare function createGlUploadCubeTextureResource(uploaders: Record<string, GLTextureUploader> & {
    image: GLTextureUploader;
}): GLTextureUploader;
