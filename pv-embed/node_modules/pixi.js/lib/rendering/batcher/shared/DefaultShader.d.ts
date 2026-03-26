import { Shader } from '../../renderers/shared/shader/Shader';
/**
 * DefaultShader is a specialized shader class designed for batch rendering.
 * It extends the base Shader class and provides functionality for handling
 * color, texture batching, and pixel rounding in both WebGL and WebGPU contexts.
 *
 * It is used by the default batcher
 * @extends Shader
 * @category rendering
 * @advanced
 */
export declare class DefaultShader extends Shader {
    /** @internal */
    maxTextures?: number;
    constructor(maxTextures: number);
}
