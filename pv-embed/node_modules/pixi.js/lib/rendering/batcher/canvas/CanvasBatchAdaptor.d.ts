import { ExtensionType } from '../../../extensions/Extensions';
import type { Geometry } from '../../renderers/shared/geometry/Geometry';
import type { Shader } from '../../renderers/shared/shader/Shader';
import type { Batch } from '../shared/Batcher';
import type { BatcherAdaptor, BatcherPipe } from '../shared/BatcherPipe';
/**
 * A BatcherAdaptor that renders batches using Canvas2D.
 * @category rendering
 * @ignore
 */
export declare class CanvasBatchAdaptor implements BatcherAdaptor {
    private static readonly _tempPatternMatrix;
    private static _getPatternRepeat;
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasPipesAdaptor];
        readonly name: "batch";
    };
    start(batchPipe: BatcherPipe, geometry: Geometry, shader: Shader): void;
    execute(batchPipe: BatcherPipe, batch: Batch): void;
}
