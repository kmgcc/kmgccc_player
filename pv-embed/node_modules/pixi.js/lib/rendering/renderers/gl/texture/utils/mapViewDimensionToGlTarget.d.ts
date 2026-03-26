import type { TextureSource } from '../../../shared/texture/sources/TextureSource';
import type { GlRenderingContext } from '../../context/GlRenderingContext';
/**
 * Builds a lookup table that maps Pixi's texture view dimension to the appropriate WebGL texture target.
 *
 * This is about how the texture is *bound/viewed* in shaders, not about how pixel data is uploaded.
 * @param gl - WebGL context.
 * @internal
 */
export declare function mapViewDimensionToGlTarget(gl: GlRenderingContext): Record<TextureSource['viewDimension'], number | null>;
