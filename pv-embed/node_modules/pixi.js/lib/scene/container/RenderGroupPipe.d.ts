import { ExtensionType } from '../../extensions/Extensions';
import { type Renderer } from '../../rendering/renderers/types';
import type { InstructionSet } from '../../rendering/renderers/shared/instructions/InstructionSet';
import type { InstructionPipe } from '../../rendering/renderers/shared/instructions/RenderPipe';
import type { RenderGroup } from './RenderGroup';
/**
 * The RenderGroupPipe is a render pipe for rendering RenderGroups.
 * @internal
 */
export declare class RenderGroupPipe implements InstructionPipe<RenderGroup> {
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "renderGroup";
    };
    private _renderer;
    constructor(renderer: Renderer);
    addRenderGroup(renderGroup: RenderGroup, instructionSet: InstructionSet): void;
    execute(renderGroup: RenderGroup): void;
    destroy(): void;
    private _addRenderableDirect;
    private _addRenderableCacheAsTexture;
    private _executeCacheAsTexture;
    private _executeDirect;
}
