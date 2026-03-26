import { ExtensionType } from '../../../extensions/Extensions';
import { State } from '../../../rendering/renderers/shared/state/State';
import type { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../../rendering/renderers/types';
import type { Graphics } from '../shared/Graphics';
import type { GraphicsAdaptor } from '../shared/GraphicsPipe';
/** @internal */
export declare class CanvasGraphicsPipe implements RenderPipe<Graphics> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasPipes];
        readonly name: "graphics";
    };
    renderer: Renderer;
    state: State;
    private _adaptor;
    private readonly _managedGraphics;
    constructor(renderer: Renderer, adaptor: GraphicsAdaptor);
    contextChange(): void;
    validateRenderable(_graphics: Graphics): boolean;
    addRenderable(graphics: Graphics, instructionSet: InstructionSet): void;
    updateRenderable(_graphics: Graphics): void;
    execute(graphics: Graphics): void;
    destroy(): void;
}
