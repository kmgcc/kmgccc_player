import { ExtensionType } from '../../../extensions/Extensions';
import { State } from '../../renderers/shared/state/State';
import type { Geometry } from '../../renderers/shared/geometry/Geometry';
import type { InstructionSet } from '../../renderers/shared/instructions/InstructionSet';
import type { BatchPipe, InstructionPipe } from '../../renderers/shared/instructions/RenderPipe';
import type { Shader } from '../../renderers/shared/shader/Shader';
import type { Renderer } from '../../renderers/types';
import type { Batch, BatchableElement, Batcher } from './Batcher';
/** @internal */
export interface BatcherAdaptor {
    start(batchPipe: BatcherPipe, geometry: Geometry, shader: Shader): void;
    init?(batchPipe: BatcherPipe): void;
    execute(batchPipe: BatcherPipe, batch: Batch): void;
    contextChange?(): void;
}
/**
 * A pipe that batches elements into batches and sends them to the renderer.
 *
 * You can install new Batchers using ExtensionType.Batcher. Each render group will
 * have a default batcher and any required ones will be created on demand.
 * @category rendering
 * @advanced
 */
export declare class BatcherPipe implements InstructionPipe<Batch>, BatchPipe {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "batch";
    };
    state: State;
    renderer: Renderer;
    private readonly _batchersByInstructionSet;
    private _adaptor;
    /** A record of all active batchers, keyed by their names */
    private _activeBatches;
    /** The currently active batcher being used to batch elements */
    private _activeBatch;
    static _availableBatchers: Record<string, new () => Batcher>;
    static getBatcher(name: string): Batcher;
    constructor(renderer: Renderer, adaptor: BatcherAdaptor);
    buildStart(instructionSet: InstructionSet): void;
    addToBatch(batchableObject: BatchableElement, instructionSet: InstructionSet): void;
    break(instructionSet: InstructionSet): void;
    buildEnd(instructionSet: InstructionSet): void;
    upload(instructionSet: InstructionSet): void;
    execute(batch: Batch): void;
    destroy(): void;
}
