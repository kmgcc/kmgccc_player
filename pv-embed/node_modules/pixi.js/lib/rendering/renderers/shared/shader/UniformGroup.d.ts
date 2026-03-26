import { type UniformData } from './types';
import type { BindResource } from '../../gpu/shader/BindResource';
import type { Buffer } from '../buffer/Buffer';
type FLOPS<T = UniformData> = T extends {
    value: infer V;
} ? V : never;
/**
 * Extracts the value type from a uniform data object.
 * @internal
 */
export type ExtractUniformObject<T = Record<string, UniformData>> = {
    [K in keyof T]: FLOPS<T[K]>;
};
/**
 * Uniform group options
 * @category rendering
 * @advanced
 */
export type UniformGroupOptions = {
    /**
     * if true the UniformGroup is handled as an Uniform buffer object.
     * This is the only way WebGPU can work with uniforms. WebGL2 can also use this.
     * So don't set to true if you want to use WebGPU :D
     */
    ubo?: boolean;
    /** if true, then you are responsible for when the data is uploaded to the GPU by calling `update()` */
    isStatic?: boolean;
};
/**
 * Uniform group holds uniform map and some ID's for work
 *
 * `UniformGroup` has two modes:
 *
 * 1: Normal mode
 * Normal mode will upload the uniforms with individual function calls as required. This is the default mode
 * for WebGL rendering.
 *
 * 2: Uniform buffer mode
 * This mode will treat the uniforms as a uniform buffer. You can pass in either a buffer that you manually handle, or
 * or a generic object that PixiJS will automatically map to a buffer for you.
 * For maximum benefits, make Ubo UniformGroups static, and only update them each frame.
 * This is the only way uniforms can be used with WebGPU.
 *
 * Rules of UBOs:
 * - UBOs only work with WebGL2, so make sure you have a fallback!
 * - Only floats are supported (including vec[2,3,4], mat[2,3,4])
 * - Samplers cannot be used in ubo's (a GPU limitation)
 * - You must ensure that the object you pass in exactly matches in the shader ubo structure.
 * Otherwise, weirdness will ensue!
 * - The name of the ubo object added to the group must match exactly the name of the ubo in the shader.
 *
 * When declaring your uniform options, you ust parse in the value and the type of the uniform.
 * The types correspond to the WebGPU types
 *
 Uniforms can be modified via the classes 'uniforms' property. It will contain all the uniforms declared in the constructor.
 *
 * ```ts
 * // UBO in shader:
 * uniform myCoolData { // Declaring a UBO...
 *     mat4 uCoolMatrix;
 *     float uFloatyMcFloatFace;
 * };
 * ```
 *
 * ```js
 * // A new Uniform Buffer Object...
 * const myCoolData = new UniformGroup({
 *     uCoolMatrix: {value:new Matrix(), type: 'mat4<f32>'},
 *     uFloatyMcFloatFace: {value:23, type: 'f32'},
 * }}
 *
 * // modify the data
 * myCoolData.uniforms.uFloatyMcFloatFace = 42;
 * // Build a shader...
 * const shader = Shader.from(srcVert, srcFrag, {
 *     myCoolData // Name matches the UBO name in the shader. Will be processed accordingly.
 * })
 * ```
 * @category rendering
 * @advanced
 */
export declare class UniformGroup<UNIFORMS extends {
    [key: string]: UniformData;
} = any> implements BindResource {
    /** The default options used by the uniform group. */
    static defaultOptions: UniformGroupOptions;
    /**
     * used internally to know if a uniform group was used in the last render pass
     * @internal
     */
    _touched: number;
    /** a unique id for this uniform group used through the renderer */
    readonly uid: number;
    /**
     * a resource type, used to identify how to handle it when its in a bind group / shader resource
     * @internal
     */
    _resourceType: string;
    /**
     * the resource id used internally by the renderer to build bind group keys
     * @internal
     */
    _resourceId: number;
    /** the structures of the uniform group */
    uniformStructures: UNIFORMS;
    /** the uniforms as an easily accessible map of properties */
    uniforms: ExtractUniformObject<UNIFORMS>;
    /** true if it should be used as a uniform buffer object */
    ubo: boolean;
    /** an underlying buffer that will be uploaded to the GPU when using this UniformGroup */
    buffer?: Buffer;
    /**
     * if true, then you are responsible for when the data is uploaded to the GPU.
     * otherwise, the data is reuploaded each frame.
     */
    isStatic: boolean;
    /** used ito identify if this is a uniform group */
    readonly isUniformGroup = true;
    /**
     * used to flag if this Uniform groups data is different from what it has stored in its buffer / on the GPU
     * @internal
     */
    _dirtyId: number;
    /**
     * a signature string generated for internal use
     * @internal
     */
    readonly _signature: number;
    readonly destroyed = false;
    /**
     * Create a new Uniform group
     * @param uniformStructures - The structures of the uniform group
     * @param options - The optional parameters of this uniform group
     */
    constructor(uniformStructures: UNIFORMS, options?: UniformGroupOptions);
    /** Call this if you want the uniform groups data to be uploaded to the GPU only useful if `isStatic` is true. */
    update(): void;
}
export {};
