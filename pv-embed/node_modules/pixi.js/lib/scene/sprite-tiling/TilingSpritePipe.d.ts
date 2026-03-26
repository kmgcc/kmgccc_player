import { ExtensionType } from '../../extensions/Extensions';
import { type Renderer } from '../../rendering/renderers/types';
import { BatchableMesh } from '../mesh/shared/BatchableMesh';
import { MeshGeometry } from '../mesh/shared/MeshGeometry';
import { type GPUData } from '../view/ViewContainer';
import { TilingSpriteShader } from './shader/TilingSpriteShader';
import type { InstructionSet } from '../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../rendering/renderers/shared/instructions/RenderPipe';
import type { TilingSprite } from './TilingSprite';
/** @internal */
export declare class TilingSpriteGpuData implements GPUData {
    canBatch: boolean;
    renderable: TilingSprite;
    batchableMesh?: BatchableMesh;
    geometry?: MeshGeometry;
    shader?: TilingSpriteShader;
    constructor();
    destroy(): void;
}
/**
 * The TilingSpritePipe is a render pipe for rendering TilingSprites.
 * It handles the batching and rendering of TilingSprites using a shader.
 * @internal
 */
export declare class TilingSpritePipe implements RenderPipe<TilingSprite> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes];
        readonly name: "tilingSprite";
    };
    private _renderer;
    private readonly _state;
    private readonly _managedTilingSprites;
    constructor(renderer: Renderer);
    validateRenderable(renderable: TilingSprite): boolean;
    addRenderable(tilingSprite: TilingSprite, instructionSet: InstructionSet): void;
    execute(tilingSprite: TilingSprite): void;
    updateRenderable(tilingSprite: TilingSprite): void;
    private _getTilingSpriteData;
    private _initTilingSpriteData;
    private _updateBatchableMesh;
    destroy(): void;
    private _updateCanBatch;
}
