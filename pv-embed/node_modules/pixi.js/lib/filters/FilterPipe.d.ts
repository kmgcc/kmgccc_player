import { ExtensionType } from '../extensions/Extensions';
import type { InstructionSet } from '../rendering/renderers/shared/instructions/InstructionSet';
import type { InstructionPipe } from '../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../rendering/renderers/types';
import type { Container } from '../scene/container/Container';
import type { Effect } from '../scene/container/Effect';
import type { FilterInstruction } from './FilterSystem';
/** @internal */
export declare class FilterPipe implements InstructionPipe<FilterInstruction> {
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "filter";
    };
    private _renderer;
    constructor(renderer: Renderer);
    push(filterEffect: Effect, container: Container, instructionSet: InstructionSet): void;
    pop(_filterEffect: Effect, _container: Container, instructionSet: InstructionSet): void;
    execute(instruction: FilterInstruction): void;
    destroy(): void;
}
