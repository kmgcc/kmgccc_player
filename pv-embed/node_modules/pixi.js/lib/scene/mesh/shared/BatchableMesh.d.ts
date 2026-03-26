import type { Matrix } from '../../../maths/matrix/Matrix';
import type { Batch, Batcher } from '../../../rendering/batcher/shared/Batcher';
import type { DefaultBatchableMeshElement } from '../../../rendering/batcher/shared/DefaultBatcher';
import type { Topology } from '../../../rendering/renderers/shared/geometry/const';
import type { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import type { ViewContainer } from '../../view/ViewContainer';
import type { MeshGeometry } from './MeshGeometry';
/**
 * A batchable mesh object.
 * @ignore
 */
export declare class BatchableMesh implements DefaultBatchableMeshElement {
    batcherName: string;
    _topology: Topology;
    readonly packAsQuad = false;
    location: number;
    renderable: ViewContainer;
    indexOffset: number;
    attributeOffset: number;
    texture: Texture;
    geometry: MeshGeometry;
    transform: Matrix;
    roundPixels: 0 | 1;
    _attributeStart: number;
    _batcher: Batcher;
    _batch: Batch;
    _indexStart: number;
    _textureId: number;
    _textureMatrixUpdateId: number;
    private _transformedUvs;
    private _uvUpdateId;
    get blendMode(): import("../../..").BLEND_MODES;
    get topology(): Topology;
    set topology(value: Topology);
    reset(): void;
    /**
     * Sets the texture for the batchable mesh.
     * As it does so, it resets the texture matrix update ID.
     * this is to ensure that the texture matrix is recalculated when the uvs are referenced
     * @param value - The texture to set.
     */
    setTexture(value: Texture): void;
    get uvs(): Float32Array;
    get positions(): Float32Array<ArrayBufferLike>;
    get indices(): Uint32Array<ArrayBufferLike>;
    get color(): number;
    get groupTransform(): Matrix;
    get attributeSize(): number;
    get indexSize(): number;
}
