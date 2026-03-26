import { GpuProgram } from '../../../../rendering/renderers/gpu/shader/GpuProgram';
/**
 * @internal
 * @param horizontal - Whether to generate a horizontal or vertical blur program.
 * @param kernelSize - The size of the kernel.
 */
export declare function generateBlurProgram(horizontal: boolean, kernelSize: number): GpuProgram;
