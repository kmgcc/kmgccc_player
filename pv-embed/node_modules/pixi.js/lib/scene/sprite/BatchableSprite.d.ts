import { type GPUData } from '../view/ViewContainer';
import type { Matrix } from '../../maths/matrix/Matrix';
import type { Batch, Batcher } from '../../rendering/batcher/shared/Batcher';
import type { DefaultBatchableQuadElement } from '../../rendering/batcher/shared/DefaultBatcher';
import type { Topology } from '../../rendering/renderers/shared/geometry/const';
import type { Texture } from '../../rendering/renderers/shared/texture/Texture';
import type { BoundsData } from '../container/bounds/Bounds';
import type { Container } from '../container/Container';
/**
 * A batchable sprite object.
 * @internal
 */
export declare class BatchableSprite implements DefaultBatchableQuadElement, GPUData {
    batcherName: string;
    topology: Topology;
    readonly attributeSize = 4;
    readonly indexSize = 6;
    readonly packAsQuad = true;
    transform: Matrix;
    renderable: Container;
    texture: Texture;
    bounds: BoundsData;
    roundPixels: 0 | 1;
    _indexStart: number;
    _textureId: number;
    _attributeStart: number;
    _batcher: Batcher;
    _batch: Batch;
    get blendMode(): import("../..").BLEND_MODES;
    get color(): number;
    reset(): void;
    destroy(): void;
}
