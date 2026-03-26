import type { BLEND_MODES } from '../../shared/state/const';
import type { GlRenderingContext } from '../context/GlRenderingContext';
/**
 * Maps gl blend combinations to WebGL.
 * @param gl
 * @returns {object} Map of gl blend combinations to WebGL.
 * @internal
 */
export declare function mapWebGLBlendModesToPixi(gl: GlRenderingContext): Record<BLEND_MODES, number[]>;
