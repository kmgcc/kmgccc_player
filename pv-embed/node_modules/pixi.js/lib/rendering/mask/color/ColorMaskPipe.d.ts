import { ExtensionType } from '../../../extensions/Extensions';
import type { Container } from '../../../scene/container/Container';
import type { Effect } from '../../../scene/container/Effect';
import type { InstructionSet } from '../../renderers/shared/instructions/InstructionSet';
import type { InstructionPipe } from '../../renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../renderers/types';
import type { ColorMaskInstruction } from './ColorMaskTypes';
/** @internal */
export declare class ColorMaskPipe implements InstructionPipe<ColorMaskInstruction> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes];
        readonly name: "colorMask";
    };
    private readonly _renderer;
    private _colorStack;
    private _colorStackIndex;
    private _currentColor;
    constructor(renderer: Renderer);
    buildStart(): void;
    push(mask: Effect, _container: Container, instructionSet: InstructionSet): void;
    pop(_mask: Effect, _container: Container, instructionSet: InstructionSet): void;
    execute(instruction: ColorMaskInstruction): void;
    destroy(): void;
}
