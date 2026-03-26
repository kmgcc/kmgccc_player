import { ExtensionType } from '../../../extensions/Extensions';
import type { System } from '../shared/system/System';
import type { GPU } from './GpuDeviceSystem';
import type { BindGroup } from './shader/BindGroup';
import type { GpuProgram } from './shader/GpuProgram';
import type { WebGPURenderer } from './WebGPURenderer';
/**
 * This manages the WebGPU bind groups. this is how data is bound to a shader when rendering
 * @category rendering
 * @advanced
 */
export declare class BindGroupSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "bindGroup";
    };
    private readonly _renderer;
    private _hash;
    private _gpu;
    constructor(renderer: WebGPURenderer);
    protected contextChange(gpu: GPU): void;
    getBindGroup(bindGroup: BindGroup, program: GpuProgram, groupIndex: number): GPUBindGroup;
    private _createBindGroup;
    destroy(): void;
}
