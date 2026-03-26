import { ExtensionType } from '../../../../extensions/Extensions';
import { type GPUData } from '../../../../scene/view/ViewContainer';
import type { Buffer } from '../../shared/buffer/Buffer';
import type { System } from '../../shared/system/System';
import type { GPU } from '../GpuDeviceSystem';
import type { WebGPURenderer } from '../WebGPURenderer';
/** @internal */
export declare class GpuBufferData implements GPUData {
    gpuBuffer: GPUBuffer;
    constructor(gpuBuffer: GPUBuffer);
    destroy(): void;
}
/**
 * System plugin to the renderer to manage buffers.
 * @category rendering
 * @advanced
 */
export declare class GpuBufferSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "buffer";
    };
    protected CONTEXT_UID: number;
    private readonly _renderer;
    private readonly _managedBuffers;
    private _gpu;
    constructor(renderer: WebGPURenderer);
    protected contextChange(gpu: GPU): void;
    getGPUBuffer(buffer: Buffer): GPUBuffer;
    updateBuffer(buffer: Buffer): GPUBuffer;
    /** dispose all WebGL resources of all managed buffers */
    destroyAll(): void;
    protected onBufferUnload(buffer: Buffer): void;
    createGPUBuffer(buffer: Buffer): GPUBuffer;
    protected onBufferChange(buffer: Buffer): void;
    destroy(): void;
}
