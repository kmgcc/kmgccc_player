import type { TextureStyle } from '../../../shared/texture/TextureStyle';
/**
 * @param style
 * @param gl
 * @param mipmaps
 * @param anisotropicExt
 * @param glFunctionName
 * @param firstParam
 * @param forceClamp
 * @param firstCreation
 * @internal
 */
export declare function applyStyleParams(style: TextureStyle, gl: WebGL2RenderingContext, mipmaps: boolean, anisotropicExt: EXT_texture_filter_anisotropic, glFunctionName: 'samplerParameteri' | 'texParameteri', firstParam: 3553 | WebGLSampler, forceClamp: boolean, 
/** if true we can skip setting certain values if the values is the same as the default gl values */
firstCreation: boolean): void;
