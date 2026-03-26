import { ExtensionType } from '../../../extensions/Extensions';
import type { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../../rendering/renderers/types';
import type { TilingSprite } from '../TilingSprite';
/** @internal */
export declare class CanvasTilingSpritePipe implements RenderPipe<TilingSprite> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasPipes];
        readonly name: "tilingSprite";
    };
    private _renderer;
    constructor(renderer: Renderer);
    validateRenderable(_renderable: TilingSprite): boolean;
    addRenderable(tilingSprite: TilingSprite, instructionSet: InstructionSet): void;
    updateRenderable(_tilingSprite: TilingSprite): void;
    execute(tilingSprite: TilingSprite): void;
    destroy(): void;
}
