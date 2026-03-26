import { ExtensionType } from '../../../extensions/Extensions';
import { BufferResource } from '../shared/buffer/BufferResource';
import { BindGroup } from './shader/BindGroup';
import type { UniformGroup } from '../shared/shader/UniformGroup';
import type { WebGPURenderer } from './WebGPURenderer';
/** @internal */
export declare class GpuUniformBatchPipe {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUPipes];
        readonly name: "uniformBatch";
    };
    private _renderer;
    private _bindGroupHash;
    private readonly _batchBuffer;
    private _buffers;
    private _bindGroups;
    private _bufferResources;
    constructor(renderer: WebGPURenderer);
    renderEnd(): void;
    private _resetBindGroups;
    getUniformBindGroup(group: UniformGroup<any>, duplicate: boolean): BindGroup;
    getUboResource(group: UniformGroup<any>): BufferResource;
    getArrayBindGroup(data: Float32Array): BindGroup;
    getArrayBufferResource(data: Float32Array): BufferResource;
    private _getBufferResource;
    private _getBindGroup;
    private _uploadBindGroups;
    destroy(): void;
}
