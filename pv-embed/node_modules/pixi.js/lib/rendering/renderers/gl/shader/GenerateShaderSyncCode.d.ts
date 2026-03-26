import type { Shader } from '../../shared/shader/Shader';
import type { GlShaderSystem, ShaderSyncFunction } from './GlShaderSystem';
/**
 * Generates the a function that will efficiently sync shader resources with the GPU.
 * @param shader - The shader to generate the code for
 * @param shaderSystem - An instance of the shader system
 * @internal
 */
export declare function generateShaderSyncCode(shader: Shader, shaderSystem: GlShaderSystem): ShaderSyncFunction;
