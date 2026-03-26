import { ExtensionType } from '../../../../extensions/Extensions';
import type { GPU } from '../GpuDeviceSystem';
import type { GpuProgram } from './GpuProgram';
/**
 * Data structure for GPU program layout.
 * Contains bind group layouts and pipeline layout.
 * @category rendering
 * @advanced
 */
export interface GPUProgramData {
    bindGroups: GPUBindGroupLayout[];
    pipeline: GPUPipelineLayout;
}
/**
 * A system that manages the rendering of GpuPrograms.
 * @category rendering
 * @advanced
 */
export declare class GpuShaderSystem {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "shader";
    };
    private _gpu;
    private readonly _gpuProgramData;
    protected contextChange(gpu: GPU): void;
    getProgramData(program: GpuProgram): GPUProgramData;
    private _createGPUProgramData;
    destroy(): void;
}
