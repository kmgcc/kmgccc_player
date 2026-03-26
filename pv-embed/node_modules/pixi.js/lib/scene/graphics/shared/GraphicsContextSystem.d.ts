import { ExtensionType } from '../../../extensions/Extensions';
import { type BatcherOptions } from '../../../rendering/batcher/shared/Batcher';
import { DefaultBatcher } from '../../../rendering/batcher/shared/DefaultBatcher';
import { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import { type GPUData } from '../../view/ViewContainer';
import type { System } from '../../../rendering/renderers/shared/system/System';
import type { Renderer } from '../../../rendering/renderers/types';
import type { BatchableGraphics } from './BatchableGraphics';
import type { GraphicsContext } from './GraphicsContext';
interface GeometryData {
    vertices: number[];
    uvs: number[];
    indices: number[];
}
/**
 * A class that holds batchable graphics data for a GraphicsContext.
 * @category rendering
 * @ignore
 */
export declare class GpuGraphicsContext implements GPUData {
    isBatchable: boolean;
    context: GraphicsContext;
    batches: BatchableGraphics[];
    geometryData: GeometryData;
    graphicsData: GraphicsContextRenderData;
    reset(): void;
    destroy(): void;
}
/**
 * A class that holds the render data for a GraphicsContext.
 * @category rendering
 * @ignore
 */
export declare class GraphicsContextRenderData {
    batcher: DefaultBatcher;
    instructions: InstructionSet;
    init(options: BatcherOptions): void;
    /**
     * @deprecated since version 8.0.0
     * Use `batcher.geometry` instead.
     * @see {Batcher#geometry}
     */
    get geometry(): import("../../..").BatchGeometry;
    destroy(): void;
}
/**
 * Options for the GraphicsContextSystem.
 * @category rendering
 * @advanced
 */
export interface GraphicsContextSystemOptions {
    /** A value from 0 to 1 that controls the smoothness of bezier curves (the higher the smoother) */
    bezierSmoothness?: number;
}
/**
 * A system that manages the rendering of GraphicsContexts.
 * @category rendering
 * @advanced
 */
export declare class GraphicsContextSystem implements System<GraphicsContextSystemOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem];
        readonly name: "graphicsContext";
    };
    /** The default options for the GraphicsContextSystem. */
    static readonly defaultOptions: GraphicsContextSystemOptions;
    private readonly _renderer;
    private readonly _managedContexts;
    constructor(renderer: Renderer);
    /**
     * Runner init called, update the default options
     * @ignore
     */
    init(options?: GraphicsContextSystemOptions): void;
    /**
     * Returns the render data for a given GraphicsContext.
     * @param context - The GraphicsContext to get the render data for.
     * @internal
     */
    getContextRenderData(context: GraphicsContext): GraphicsContextRenderData;
    /**
     * Updates the GPU context for a given GraphicsContext.
     * If the context is dirty, it will rebuild the batches and geometry data.
     * @param context - The GraphicsContext to update.
     * @returns The updated GpuGraphicsContext.
     * @internal
     */
    updateGpuContext(context: GraphicsContext): GpuGraphicsContext;
    /**
     * Returns the GpuGraphicsContext for a given GraphicsContext.
     * If it does not exist, it will initialize a new one.
     * @param context - The GraphicsContext to get the GpuGraphicsContext for.
     * @returns The GpuGraphicsContext for the given GraphicsContext.
     * @internal
     */
    getGpuContext(context: GraphicsContext): GpuGraphicsContext;
    private _initContextRenderData;
    private _initContext;
    destroy(): void;
}
export {};
