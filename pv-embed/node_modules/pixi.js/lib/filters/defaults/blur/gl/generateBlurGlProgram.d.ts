import { GlProgram } from '../../../../rendering/renderers/gl/shader/GlProgram';
/**
 * @internal
 * @param horizontal - Whether to generate a horizontal or vertical blur program.
 * @param kernelSize - The size of the kernel.
 */
export declare function generateBlurGlProgram(horizontal: boolean, kernelSize: number): GlProgram;
