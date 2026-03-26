import type { TEXTURE_FORMATS } from '../const';
/** @internal */
export declare const nonCompressedFormats: TEXTURE_FORMATS[];
/** @internal */
export declare function getSupportedTextureFormats(): Promise<TEXTURE_FORMATS[]>;
