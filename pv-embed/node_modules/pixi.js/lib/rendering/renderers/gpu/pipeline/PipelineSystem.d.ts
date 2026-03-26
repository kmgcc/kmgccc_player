import { ExtensionType } from '../../../../extensions/Extensions';
import { STENCIL_MODES } from '../../shared/state/const';
import type { Topology } from '../../shared/geometry/const';
import type { Geometry } from '../../shared/geometry/Geometry';
import type { State } from '../../shared/state/State';
import type { System } from '../../shared/system/System';
import type { GPU } from '../GpuDeviceSystem';
import type { GpuRenderTarget } from '../renderTarget/GpuRenderTarget';
import type { GpuProgram } from '../shader/GpuProgram';
import type { WebGPURenderer } from '../WebGPURenderer';
/**
 * A system that creates and manages the GPU pipelines.
 *
 * Caching Mechanism: At its core, the system employs a two-tiered caching strategy to minimize
 * the redundant creation of GPU pipelines (or "pipes"). This strategy is based on generating unique
 * keys that represent the state of the graphics settings and the specific requirements of the
 * item being rendered. By caching these pipelines, subsequent draw calls with identical configurations
 * can reuse existing pipelines instead of generating new ones.
 *
 * State Management: The system differentiates between "global" state properties (like color masks
 * and stencil masks, which do not change frequently) and properties that may vary between draw calls
 * (such as geometry, shaders, and blend modes). Unique keys are generated for both these categories
 * using getStateKey for global state and getGraphicsStateKey for draw-specific settings. These keys are
 * then then used to caching the pipe. The next time we need a pipe we can check
 * the cache by first looking at the state cache and then the pipe cache.
 * @category rendering
 * @advanced
 */
export declare class PipelineSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "pipeline";
    };
    private readonly _renderer;
    protected CONTEXT_UID: number;
    private _moduleCache;
    private _bufferLayoutsCache;
    private readonly _bindingNamesCache;
    private _pipeCache;
    private readonly _pipeStateCaches;
    private _gpu;
    private _stencilState;
    private _stencilMode;
    private _colorMask;
    private _multisampleCount;
    private _colorTargetCount;
    private _depthStencilAttachment;
    constructor(renderer: WebGPURenderer);
    protected contextChange(gpu: GPU): void;
    setMultisampleCount(multisampleCount: number): void;
    setRenderTarget(renderTarget: GpuRenderTarget): void;
    setColorMask(colorMask: number): void;
    setStencilMode(stencilMode: STENCIL_MODES): void;
    setPipeline(geometry: Geometry, program: GpuProgram, state: State, passEncoder: GPURenderPassEncoder): void;
    getPipeline(geometry: Geometry, program: GpuProgram, state: State, topology?: Topology): GPURenderPipeline;
    private _createPipeline;
    private _getModule;
    private _createModule;
    private _generateBufferKey;
    private _generateAttributeLocationsKey;
    /**
     * Returns a hash of buffer names mapped to bind locations.
     * This is used to bind the correct buffer to the correct location in the shader.
     * @param geometry - The geometry where to get the buffer names
     * @param program - The program where to get the buffer names
     * @returns An object of buffer names mapped to the bind location.
     */
    getBufferNamesToBind(geometry: Geometry, program: GpuProgram): Record<string, string>;
    private _createVertexBufferLayouts;
    private _updatePipeHash;
    destroy(): void;
}
