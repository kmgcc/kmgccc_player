import type { GlUniformBlockData } from '../GlProgram';
/**
 * returns the uniform block data from the program
 * @private
 * @param program - the webgl program
 * @param gl - the WebGL context
 * @returns {object} the uniform data for this program
 */
export declare function getUboData(program: WebGLProgram, gl: WebGL2RenderingContext): Record<string, GlUniformBlockData>;
