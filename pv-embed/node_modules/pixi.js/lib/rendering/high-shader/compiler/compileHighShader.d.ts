import type { HighShaderBit, HighShaderSource } from './types';
/**
 * A high template consists of vertex and fragment source
 * @internal
 */
export interface HighShaderTemplate {
    name?: string;
    fragment: string;
    vertex: string;
}
/** @internal */
export interface CompileHighShaderOptions {
    template: HighShaderTemplate;
    bits: HighShaderBit[];
}
/**
 * This function will take a HighShader template, some High fragments and then merge them in to a shader source.
 * @param options
 * @param options.template
 * @param options.bits
 * @internal
 */
export declare function compileHighShader({ template, bits }: CompileHighShaderOptions): HighShaderSource;
/**
 * This function will take a HighShader template, some High fragments and then merge them in to a shader source.
 * It is specifically for WebGL and does not compile inputs and outputs.
 * @param options
 * @param options.template - The HighShader template containing vertex and fragment source.
 * @param options.bits - An array of HighShaderBit objects to be compiled into the shader.
 * @returns A HighShaderSource object containing the compiled vertex and fragment shaders.
 * @internal
 */
export declare function compileHighShaderGl({ template, bits }: CompileHighShaderOptions): HighShaderSource;
