import type { GlRenderingContext } from '../../context/GlRenderingContext';
import type { WebGLExtensions } from '../../context/WebGLExtensions';
/**
 * Returns a lookup table that maps each type-format pair to a compatible internal format.
 * @function mapTypeAndFormatToInternalFormat
 * @private
 * @param gl - The rendering context.
 * @param extensions - The WebGL extensions.
 * @returns Lookup table.
 */
export declare function mapFormatToGlInternalFormat(gl: GlRenderingContext, extensions: WebGLExtensions): Record<string, number>;
