import { ExtensionType } from '../../../extensions/Extensions';
import { State } from '../../../rendering/renderers/shared/state/State';
import { type Renderer } from '../../../rendering/renderers/types';
import { type GPUData } from '../../view/ViewContainer';
import { BatchableGraphics } from './BatchableGraphics';
import type { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../../rendering/renderers/shared/instructions/RenderPipe';
import type { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import type { Graphics } from './Graphics';
/** @internal */
export interface GraphicsPipeLike {
    renderer: Renderer;
    state: State;
}
/** @internal */
export interface GraphicsAdaptor {
    shader: Shader;
    contextChange(renderer: Renderer): void;
    execute(graphicsPipe: GraphicsPipeLike, renderable: Graphics): void;
    destroy(): void;
}
/** @internal */
export declare class GraphicsGpuData implements GPUData {
    batches: BatchableGraphics[];
    batched: boolean;
    destroy(): void;
}
/** @internal */
export declare class GraphicsPipe implements RenderPipe<Graphics> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes];
        readonly name: "graphics";
    };
    renderer: Renderer;
    state: State;
    private _adaptor;
    private readonly _managedGraphics;
    constructor(renderer: Renderer, adaptor: GraphicsAdaptor);
    contextChange(): void;
    validateRenderable(graphics: Graphics): boolean;
    addRenderable(graphics: Graphics, instructionSet: InstructionSet): void;
    updateRenderable(graphics: Graphics): void;
    execute(graphics: Graphics): void;
    private _rebuild;
    private _addToBatcher;
    private _getGpuDataForRenderable;
    private _initGpuDataForRenderable;
    private _updateBatchesForRenderable;
    destroy(): void;
}
