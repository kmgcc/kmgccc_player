import type { Attribute } from '../../../shared/geometry/Geometry';
/**
 * This interface represents the extracted attribute data from a WebGL program.
 * It extends the `Attribute` interface but omits the `buffer` property.
 * It includes an optional `location` property that indicates where the shader location is for this attribute.
 * @category rendering
 * @advanced
 */
export interface ExtractedAttributeData extends Omit<Attribute, 'buffer'> {
    /** set where the shader location is for this attribute */
    location?: number;
}
/**
 * returns the attribute data from the program
 * @private
 * @param {WebGLProgram} [program] - the WebGL program
 * @param {WebGLRenderingContext} [gl] - the WebGL context
 * @param sortAttributes
 * @returns {object} the attribute data for this program
 */
export declare function extractAttributesFromGlProgram(program: WebGLProgram, gl: WebGLRenderingContextBase, sortAttributes?: boolean): Record<string, ExtractedAttributeData>;
