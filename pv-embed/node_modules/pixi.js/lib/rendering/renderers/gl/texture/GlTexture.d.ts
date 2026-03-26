import { type GPUData } from '../../../../scene/view/ViewContainer';
import { GL_FORMATS, GL_TARGETS } from './const';
/**
 * Internal texture for WebGL context
 * @category rendering
 * @ignore
 */
export declare class GlTexture implements GPUData {
    target: GL_TARGETS;
    /** The WebGL texture. */
    texture: WebGLTexture;
    /**
     * Bitmask tracking which array layers / sub-targets have been initialized at mip level 0.
     * Used by uploaders that need per-layer allocation semantics (e.g. cube faces).
     * @internal
     */
    _layerInitMask: number;
    /** Width of texture that was used in texImage2D. */
    width: number;
    /** Height of texture that was used in texImage2D. */
    height: number;
    /** Whether mip levels has to be generated. */
    mipmap: boolean;
    /** Type copied from texture source. */
    type: number;
    /** Type copied from texture source. */
    internalFormat: number;
    /** Type of sampler corresponding to this texture. See {@link SAMPLER_TYPES} */
    samplerType: number;
    format: GL_FORMATS;
    constructor(texture: WebGLTexture);
    destroy(): void;
}
