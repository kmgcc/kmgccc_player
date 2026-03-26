import { GlProgramData } from '../GlProgramData';
import type { GlRenderingContext } from '../../context/GlRenderingContext';
import type { GlProgram } from '../GlProgram';
/**
 * generates a WebGL Program object from a high level Pixi Program.
 * @param gl - a rendering context on which to generate the program
 * @param program - the high level Pixi Program.
 * @private
 */
export declare function generateProgram(gl: GlRenderingContext, program: GlProgram): GlProgramData;
