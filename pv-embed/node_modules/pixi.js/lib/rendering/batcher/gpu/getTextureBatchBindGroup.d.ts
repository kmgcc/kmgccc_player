import { BindGroup } from '../../renderers/gpu/shader/BindGroup';
import type { TextureSource } from '../../renderers/shared/texture/sources/TextureSource';
/**
 * @param textures
 * @param size
 * @param maxTextures
 * @internal
 */
export declare function getTextureBatchBindGroup(textures: TextureSource[], size: number, maxTextures: number): BindGroup;
