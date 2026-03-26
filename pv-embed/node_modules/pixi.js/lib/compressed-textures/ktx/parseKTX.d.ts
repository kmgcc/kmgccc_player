import type { TEXTURE_FORMATS } from '../../rendering/renderers/shared/texture/const';
import type { TextureSourceOptions } from '../../rendering/renderers/shared/texture/sources/TextureSource';
/**
 * @param arrayBuffer
 * @param supportedFormats
 * @internal
 */
export declare function parseKTX(arrayBuffer: ArrayBuffer, supportedFormats: TEXTURE_FORMATS[]): TextureSourceOptions<Uint8Array[]>;
