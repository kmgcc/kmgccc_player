import { ExtensionType } from '../../../extensions/Extensions';
import type { Rectangle } from '../../../maths/shapes/Rectangle';
import type { Topology } from '../shared/geometry/const';
import type { Geometry } from '../shared/geometry/Geometry';
import type { Shader } from '../shared/shader/Shader';
import type { State } from '../shared/state/State';
import type { System } from '../shared/system/System';
import type { GPU } from './GpuDeviceSystem';
import type { GpuRenderTarget } from './renderTarget/GpuRenderTarget';
import type { BindGroup } from './shader/BindGroup';
import type { GpuProgram } from './shader/GpuProgram';
import type { WebGPURenderer } from './WebGPURenderer';
/**
 * The system that handles encoding commands for the GPU.
 * @category rendering
 * @advanced
 */
export declare class GpuEncoderSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "encoder";
        readonly priority: 1;
    };
    commandEncoder: GPUCommandEncoder;
    renderPassEncoder: GPURenderPassEncoder;
    commandFinished: Promise<void>;
    private _resolveCommandFinished;
    private _gpu;
    private _boundBindGroup;
    private _boundVertexBuffer;
    private _boundIndexBuffer;
    private _boundPipeline;
    private readonly _renderer;
    constructor(renderer: WebGPURenderer);
    renderStart(): void;
    beginRenderPass(gpuRenderTarget: GpuRenderTarget): void;
    endRenderPass(): void;
    setViewport(viewport: Rectangle): void;
    setPipelineFromGeometryProgramAndState(geometry: Geometry, program: GpuProgram, state: any, topology?: Topology): void;
    setPipeline(pipeline: GPURenderPipeline): void;
    private _setVertexBuffer;
    private _setIndexBuffer;
    resetBindGroup(index: number): void;
    setBindGroup(index: number, bindGroup: BindGroup, program: GpuProgram): void;
    setGeometry(geometry: Geometry, program: GpuProgram): void;
    private _setShaderBindGroups;
    private _syncBindGroup;
    draw(options: {
        geometry: Geometry;
        shader: Shader;
        state?: State;
        topology?: Topology;
        size?: number;
        start?: number;
        instanceCount?: number;
        skipSync?: boolean;
    }): void;
    finishRenderPass(): void;
    postrender(): void;
    restoreRenderPass(): void;
    private _clearCache;
    destroy(): void;
    protected contextChange(gpu: GPU): void;
}
