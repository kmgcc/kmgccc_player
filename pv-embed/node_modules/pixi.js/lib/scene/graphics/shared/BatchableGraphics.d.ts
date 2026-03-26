import { Matrix } from '../../../maths/matrix/Matrix';
import type { Batch, Batcher } from '../../../rendering/batcher/shared/Batcher';
import type { DefaultBatchableMeshElement } from '../../../rendering/batcher/shared/DefaultBatcher';
import type { Topology } from '../../../rendering/renderers/shared/geometry/const';
import type { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import type { Graphics } from './Graphics';
/**
 * A batchable graphics object.
 * @ignore
 */
export declare class BatchableGraphics implements DefaultBatchableMeshElement {
    readonly packAsQuad = false;
    batcherName: string;
    texture: Texture;
    topology: Topology;
    renderable: Graphics;
    indexOffset: number;
    indexSize: number;
    attributeOffset: number;
    attributeSize: number;
    baseColor: number;
    alpha: number;
    applyTransform: boolean;
    roundPixels: 0 | 1;
    _indexStart: number;
    _textureId: number;
    _attributeStart: number;
    _batcher: Batcher;
    _batch: Batch;
    geometryData: {
        vertices: number[];
        uvs: number[];
        indices: number[];
    };
    get uvs(): number[];
    get positions(): number[];
    get indices(): number[];
    get blendMode(): import("../../..").BLEND_MODES;
    get color(): number;
    get transform(): Matrix;
    copyTo(gpuBuffer: BatchableGraphics): void;
    reset(): void;
    destroy(): void;
}
