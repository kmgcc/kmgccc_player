import type { ExtractedAttributeData } from '../../gl/shader/program/extractAttributesFromGlProgram';
import type { StructsAndGroups } from './utils/extractStructAndGroups';
/**
 * a WebGPU descriptions of how the program is laid out
 * @see https://gpuweb.github.io/gpuweb/#gpupipelinelayout
 * @category rendering
 * @advanced
 */
export type ProgramPipelineLayoutDescription = GPUBindGroupLayoutEntry[][];
/**
 * a map the maps names of uniforms to group indexes
 * @category rendering
 * @advanced
 */
export type ProgramLayout = Record<string, number>[];
/**
 * the program source
 * @category rendering
 * @advanced
 */
export interface ProgramSource {
    /** The wgsl source code of the shader. */
    source: string;
    /** The main function to run in this shader */
    entryPoint?: string;
}
/**
 * The options for the gpu program
 * @category rendering
 * @advanced
 */
export interface GpuProgramOptions {
    /**
     * the name of the program, this is added to the label of the GPU Program created
     * under the hood. Makes it much easier to debug!
     */
    name?: string;
    /** The fragment glsl shader source. */
    fragment?: ProgramSource;
    /** The vertex glsl shader source. */
    vertex?: ProgramSource;
    /** The layout of the program. If not provided, it will be generated from the shader sources. */
    layout?: ProgramLayout;
    /** The gpu layout of the program. If not provided, it will be generated from the shader sources. */
    gpuLayout?: ProgramPipelineLayoutDescription;
}
/**
 * A wrapper for a WebGPU Program, specifically designed for the WebGPU renderer.
 * This class facilitates the creation and management of shader code that integrates with the WebGPU pipeline.
 *
 * To leverage the full capabilities of this class, familiarity with WGSL shaders is recommended.
 * @see https://gpuweb.github.io/gpuweb/#index
 * @example
 *
 * // Create a new program
 * const program = new GpuProgram({
 *   vertex: {
 *    source: '...',
 *    entryPoint: 'main',
 *   },
 *   fragment:{
 *    source: '...',
 *    entryPoint: 'main',
 *   },
 * });
 *
 *
 * Note: Both fragment and vertex shader sources can coexist within a single WGSL source file
 * this can make things a bit simpler.
 *
 * For optimal usage and best performance, it help to reuse programs whenever possible.
 * The {@link GpuProgram.from} helper function is designed for this purpose, utilizing an
 * internal cache to efficiently manage and retrieve program instances.
 * By leveraging this function, you can significantly reduce overhead and enhance the performance of your rendering pipeline.
 *
 * An important distinction between WebGL and WebGPU regarding program data retrieval:
 * While WebGL allows extraction of program information directly from its compiled state,
 * WebGPU does not offer such a capability. Therefore, in the context of WebGPU, we're required
 * to manually extract the program layout information from the source code itself.
 * @category rendering
 * @advanced
 */
export declare class GpuProgram {
    /** The fragment glsl shader source. */
    readonly fragment?: ProgramSource;
    /** The vertex glsl shader source */
    readonly vertex?: ProgramSource;
    /**
     * Mapping of uniform names to group indexes for organizing shader program uniforms.
     * Automatically generated from shader sources if not provided.
     * @example
     * // Assuming a shader with two uniforms, `u_time` and `u_resolution`, grouped respectively:
     * [
     *   { "u_time": 0 },
     *   { "u_resolution": 1 }
     * ]
     */
    readonly layout: ProgramLayout;
    /**
     * Configuration for the WebGPU bind group layouts, detailing resource organization for the shader.
     * Generated from shader sources if not explicitly provided.
     * @example
     * // Assuming a shader program that requires two bind groups:
     * [
     *   // First bind group layout entries
     *   [{ binding: 0, visibility: GPUShaderStage.VERTEX, type: "uniform-buffer" }],
     *   // Second bind group layout entries
     *   [{ binding: 1, visibility: GPUShaderStage.FRAGMENT, type: "sampler" },
     *    { binding: 2, visibility: GPUShaderStage.FRAGMENT, type: "sampled-texture" }]
     * ]
     */
    readonly gpuLayout: ProgramPipelineLayoutDescription;
    /** @internal */
    _layoutKey: number;
    /** @internal */
    _cacheKey: string;
    /** @internal */
    _attributeLocationsKey: number;
    /** the structs and groups extracted from the shader sources */
    readonly structsAndGroups: StructsAndGroups;
    /**
     * the name of the program, this is added to the label of the GPU Program created under the hood.
     * Makes it much easier to debug!
     */
    readonly name: string;
    private _attributeData;
    /** if true, the program will automatically assign global uniforms to group[0] */
    autoAssignGlobalUniforms: boolean;
    /** if true, the program will automatically assign local uniforms to group[1] */
    autoAssignLocalUniforms: boolean;
    /**
     * Create a new GpuProgram
     * @param options - The options for the gpu program
     */
    constructor(options: GpuProgramOptions);
    private _generateProgramKey;
    get attributeData(): Record<string, ExtractedAttributeData>;
    /** destroys the program */
    destroy(): void;
    /**
     * Helper function that creates a program for a given source.
     * It will check the program cache if the program has already been created.
     * If it has that one will be returned, if not a new one will be created and cached.
     * @param options - The options for the program.
     * @returns A program using the same source
     */
    static from(options: GpuProgramOptions): GpuProgram;
}
