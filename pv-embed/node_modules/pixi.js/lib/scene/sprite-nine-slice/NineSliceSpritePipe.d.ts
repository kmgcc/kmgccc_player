import { ExtensionType } from '../../extensions/Extensions';
import { BatchableMesh } from '../mesh/shared/BatchableMesh';
import { type GPUData } from '../view/ViewContainer';
import type { InstructionSet } from '../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../rendering/renderers/types';
import type { NineSliceSprite } from './NineSliceSprite';
/**
 * GPU data for NineSliceSprite.
 * @internal
 */
export declare class NineSliceSpriteGpuData extends BatchableMesh implements GPUData {
    constructor();
    destroy(): void;
}
/**
 * The NineSliceSpritePipe is a render pipe for rendering NineSliceSprites.
 * @internal
 */
export declare class NineSliceSpritePipe implements RenderPipe<NineSliceSprite> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes];
        readonly name: "nineSliceSprite";
    };
    private readonly _renderer;
    private readonly _managedSprites;
    constructor(renderer: Renderer);
    addRenderable(sprite: NineSliceSprite, instructionSet: InstructionSet): void;
    updateRenderable(sprite: NineSliceSprite): void;
    validateRenderable(sprite: NineSliceSprite): boolean;
    private _updateBatchableSprite;
    private _getGpuSprite;
    private _initGPUSprite;
    destroy(): void;
}
