import type { TypedArray } from '../../shared/buffer/Buffer';
import type { ExtractedAttributeData } from './program/extractAttributesFromGlProgram';
/** @internal */
export interface GlUniformData {
    name: string;
    index: number;
    type: string;
    size: number;
    isArray: boolean;
    value: any;
}
/** @internal */
export interface GlUniformBlockData {
    index: number;
    name: string;
    size: number;
    value?: TypedArray;
}
/**
 * The options for the gl program
 * @category rendering
 * @advanced
 */
export interface GlProgramOptions {
    /** The fragment glsl shader source. */
    fragment: string;
    /** The vertex glsl shader source. */
    vertex: string;
    /** the name of the program, defaults to 'pixi-program' */
    name?: string;
    /** the preferred vertex precision for the shader, this may not be used if the device does not support it  */
    preferredVertexPrecision?: string;
    /** the preferred fragment precision for the shader, this may not be used if the device does not support it  */
    preferredFragmentPrecision?: string;
    transformFeedbackVaryings?: {
        names: string[];
        bufferMode: 'separate' | 'interleaved';
    };
}
/**
 * A wrapper for a WebGL Program. You can create one and then pass it to a shader.
 * This will manage the WebGL program that is compiled and uploaded to the GPU.
 *
 * To get the most out of this class, you should be familiar with glsl shaders and how they work.
 * @see https://developer.mozilla.org/en-US/docs/Web/API/WebGLProgram
 * @example
 *
 * // Create a new program
 * const program = new GlProgram({
 *   vertex: '...',
 *   fragment: '...',
 * });
 *
 *
 * There are a few key things that pixi shader will do for you automatically:
 * <br>
 * - If no precision is provided in the shader, it will be injected into the program source for you.
 * This precision will be taken form the options provided, if none is provided,
 * then the program will default to the defaultOptions.
 * <br>
 * - It will inject the program name into the shader source if none is provided.
 * <br>
 *  - It will set the program version to 300 es.
 *
 * For optimal usage and best performance, its best to reuse programs as much as possible.
 * You should use the {@link GlProgram.from} helper function to create programs.
 * @class
 * @category rendering
 * @advanced
 */
export declare class GlProgram {
    /** The default options used by the program. */
    static defaultOptions: Partial<GlProgramOptions>;
    /** the fragment glsl shader source. */
    readonly fragment?: string;
    /** the vertex glsl shader source */
    readonly vertex?: string;
    /**
     * attribute data extracted from the program once created this happens when the program is used for the first time
     * @internal
     */
    _attributeData: Record<string, ExtractedAttributeData>;
    /**
     * uniform data extracted from the program once created this happens when the program is used for the first time
     * @internal
     */
    _uniformData: Record<string, GlUniformData>;
    /**
     * uniform data extracted from the program once created this happens when the program is used for the first time
     * @internal
     */
    _uniformBlockData: Record<string, GlUniformBlockData>;
    /** details on how to use this program with transform feedback */
    transformFeedbackVaryings?: {
        names: string[];
        bufferMode: 'separate' | 'interleaved';
    };
    /**
     * the key that identifies the program via its source vertex + fragment
     * @internal
     */
    readonly _key: number;
    /**
     * A cache key used to identify the program instance.
     * @internal
     */
    _cacheKey: string;
    /**
     * Creates a shiny new GlProgram. Used by WebGL renderer.
     * @param options - The options for the program.
     */
    constructor(options: GlProgramOptions);
    /** destroys the program */
    destroy(): void;
    /**
     * Helper function that creates a program for a given source.
     * It will check the program cache if the program has already been created.
     * If it has that one will be returned, if not a new one will be created and cached.
     * @param options - The options for the program.
     * @returns A program using the same source
     */
    static from(options: GlProgramOptions): GlProgram;
}
