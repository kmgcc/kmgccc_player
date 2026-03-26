import type { GlRenderingContext } from '../../context/GlRenderingContext';
/**
 * Returns a lookup table that maps each type-format pair to a compatible internal format.
 * @function mapTypeAndFormatToInternalFormat
 * @private
 * @param {WebGLRenderingContext} gl - The rendering context.
 * @returns Lookup table.
 */
export declare function mapFormatToGlFormat(gl: GlRenderingContext): Record<string, number>;
