import { ExtensionType } from '../../../extensions/Extensions';
import type { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../../rendering/renderers/types';
import type { NineSliceSprite } from '../NineSliceSprite';
/**
 * The NineSliceSpritePipe is a render pipe for rendering NineSliceSprites with Canvas2D.
 * @internal
 */
export declare class CanvasNineSliceSpritePipe implements RenderPipe<NineSliceSprite> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasPipes];
        readonly name: "nineSliceSprite";
    };
    private _renderer;
    constructor(renderer: Renderer);
    validateRenderable(_sprite: NineSliceSprite): boolean;
    addRenderable(sprite: NineSliceSprite, instructionSet: InstructionSet): void;
    updateRenderable(_sprite: NineSliceSprite): void;
    execute(sprite: NineSliceSprite): void;
    destroy(): void;
}
