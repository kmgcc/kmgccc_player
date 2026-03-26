import { ExtensionType } from '../../../extensions/Extensions';
import type { Container } from '../../../scene/container/Container';
import type { Effect } from '../../../scene/container/Effect';
import type { InstructionSet } from '../../renderers/shared/instructions/InstructionSet';
import type { InstructionPipe } from '../../renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../renderers/types';
import type { StencilMaskInstruction } from './StencilMaskTypes';
/** @internal */
export declare class CanvasStencilMaskPipe implements InstructionPipe<StencilMaskInstruction> {
    static extension: {
        readonly type: readonly [ExtensionType.CanvasPipes];
        readonly name: "stencilMask";
    };
    private _renderer;
    private _warnedMaskTypes;
    private _canvasMaskStack;
    constructor(renderer: Renderer);
    push(mask: Effect, _container: Container, instructionSet: InstructionSet): void;
    pop(_mask: Effect, _container: Container, instructionSet: InstructionSet): void;
    execute(instruction: StencilMaskInstruction): void;
    destroy(): void;
    private _warnOnce;
}
