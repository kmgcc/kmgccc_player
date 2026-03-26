import { ExtensionType } from '../../../extensions/Extensions';
import { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import { type GPUData } from '../../view/ViewContainer';
import type { System } from '../../../rendering/renderers/shared/system/System';
import type { Renderer } from '../../../rendering/renderers/types';
import type { GraphicsContext } from '../shared/GraphicsContext';
import type { GraphicsContextSystemOptions } from '../shared/GraphicsContextSystem';
declare class CanvasGraphicsContext implements GPUData {
    /**
     * Whether this context can be batched.
     * @advanced
     */
    isBatchable: boolean;
    /**
     * The source GraphicsContext.
     * @advanced
     */
    context: GraphicsContext;
    /**
     * Render data for this context.
     * @advanced
     */
    graphicsData: CanvasGraphicsContextRenderData;
    /**
     * Reset cached canvas data.
     * @advanced
     */
    reset(): void;
    /**
     * Destroy the cached data.
     * @advanced
     */
    destroy(): void;
}
declare class CanvasGraphicsContextRenderData {
    /**
     * Instructions for canvas rendering.
     * @advanced
     */
    instructions: InstructionSet;
    /**
     * Initialize render data.
     * @advanced
     */
    init(): void;
    /**
     * Destroy render data.
     * @advanced
     */
    destroy(): void;
}
/**
 * A system that manages the rendering of GraphicsContexts for Canvas2D.
 * @category rendering
 * @advanced
 */
export declare class CanvasGraphicsContextSystem implements System<GraphicsContextSystemOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasSystem];
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
    getContextRenderData(context: GraphicsContext): CanvasGraphicsContextRenderData;
    /**
     * Updates the GPU context for a given GraphicsContext.
     * @param context - The GraphicsContext to update.
     * @returns The updated CanvasGraphicsContext.
     * @internal
     */
    updateGpuContext(context: GraphicsContext): CanvasGraphicsContext;
    /**
     * Returns the CanvasGraphicsContext for a given GraphicsContext.
     * If it does not exist, it will initialize a new one.
     * @param context - The GraphicsContext to get the CanvasGraphicsContext for.
     * @returns The CanvasGraphicsContext for the given GraphicsContext.
     * @internal
     */
    getGpuContext(context: GraphicsContext): CanvasGraphicsContext;
    private _initContextRenderData;
    private _initContext;
    destroy(): void;
}
export {};
