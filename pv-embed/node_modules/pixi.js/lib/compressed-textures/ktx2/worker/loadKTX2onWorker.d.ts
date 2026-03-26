import type { TEXTURE_FORMATS } from '../../../rendering/renderers/shared/texture/const';
import type { TextureSourceOptions } from '../../../rendering/renderers/shared/texture/sources/TextureSource';
/**
 * @param url
 * @param supportedTextures
 * @internal
 */
export declare function loadKTX2onWorker(url: string, supportedTextures: TEXTURE_FORMATS[]): Promise<TextureSourceOptions>;
