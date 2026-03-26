import { GlProgram } from '../renderers/gl/shader/GlProgram';
import { GpuProgram } from '../renderers/gpu/shader/GpuProgram';
import type { HighShaderBit } from './compiler/types';
/**
 * @param root0
 * @param root0.bits
 * @param root0.name
 * @internal
 */
export declare function compileHighShaderGpuProgram({ bits, name }: {
    bits: HighShaderBit[];
    name: string;
}): GpuProgram;
/**
 * @param root0
 * @param root0.bits
 * @param root0.name
 * @internal
 */
export declare function compileHighShaderGlProgram({ bits, name }: {
    bits: HighShaderBit[];
    name: string;
}): GlProgram;
