import { ExtensionType } from '../../../extensions/Extensions';
import type { Geometry } from '../../renderers/shared/geometry/Geometry';
import type { Shader } from '../../renderers/shared/shader/Shader';
import type { Batch } from '../shared/Batcher';
import type { BatcherAdaptor, BatcherPipe } from '../shared/BatcherPipe';
/**
 * A BatcherAdaptor that uses WebGL to render batches.
 * @category rendering
 * @ignore
 */
export declare class GlBatchAdaptor implements BatcherAdaptor {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipesAdaptor];
        readonly name: "batch";
    };
    private readonly _tempState;
    /**
     * We only want to sync the a batched shaders uniforms once on first use
     * this is a hash of shader uids to a boolean value.  When the shader is first bound
     * we set the value to true.  When the shader is bound again we check the value and
     * if it is true we know that the uniforms have already been synced and we skip it.
     */
    private _didUploadHash;
    init(batcherPipe: BatcherPipe): void;
    contextChange(): void;
    start(batchPipe: BatcherPipe, geometry: Geometry, shader: Shader): void;
    execute(batchPipe: BatcherPipe, batch: Batch): void;
}
