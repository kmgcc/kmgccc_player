import { ExtensionType } from '../../../extensions/Extensions';
import { FilterEffect } from '../../../filters/FilterEffect';
import { Sprite } from '../../../scene/sprite/Sprite';
import { Texture } from '../../renderers/shared/texture/Texture';
import type { Container } from '../../../scene/container/Container';
import type { Effect } from '../../../scene/container/Effect';
import type { PoolItem } from '../../../utils/pool/Pool';
import type { Instruction } from '../../renderers/shared/instructions/Instruction';
import type { InstructionSet } from '../../renderers/shared/instructions/InstructionSet';
import type { InstructionPipe } from '../../renderers/shared/instructions/RenderPipe';
import type { RenderTarget } from '../../renderers/shared/renderTarget/RenderTarget';
import type { Renderer } from '../../renderers/types';
import type { AlphaMask } from './AlphaMask';
type MaskMode = 'pushMaskBegin' | 'pushMaskEnd' | 'popMaskBegin' | 'popMaskEnd';
/** @internal */
declare class AlphaMaskEffect extends FilterEffect implements PoolItem {
    constructor();
    get sprite(): Sprite;
    set sprite(value: Sprite);
    get inverse(): boolean;
    set inverse(value: boolean);
    init: () => void;
}
/** @internal */
export interface AlphaMaskInstruction extends Instruction {
    renderPipeId: 'alphaMask';
    action: MaskMode;
    mask: AlphaMask;
    inverse: boolean;
    maskedContainer: Container;
    renderMask: boolean;
}
/** @internal */
export interface AlphaMaskData {
    filterEffect: AlphaMaskEffect;
    maskedContainer: Container;
    previousRenderTarget?: RenderTarget;
    filterTexture?: Texture;
}
/** @internal */
export declare class AlphaMaskPipe implements InstructionPipe<AlphaMaskInstruction> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "alphaMask";
    };
    private _renderer;
    private _activeMaskStage;
    constructor(renderer: Renderer);
    push(mask: Effect, maskedContainer: Container, instructionSet: InstructionSet): void;
    pop(mask: Effect, _maskedContainer: Container, instructionSet: InstructionSet): void;
    execute(instruction: AlphaMaskInstruction): void;
    destroy(): void;
}
export {};
