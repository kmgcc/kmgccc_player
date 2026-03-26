import { ViewableBuffer } from '../../../utils/data/ViewableBuffer';
import { type BLEND_MODES } from '../../renderers/shared/state/const';
import { BatchTextureArray } from './BatchTextureArray';
import type { BoundsData } from '../../../scene/container/bounds/Bounds';
import type { BindGroup } from '../../renderers/gpu/shader/BindGroup';
import type { Topology } from '../../renderers/shared/geometry/const';
import type { Geometry, IndexBufferArray } from '../../renderers/shared/geometry/Geometry';
import type { Instruction } from '../../renderers/shared/instructions/Instruction';
import type { InstructionSet } from '../../renderers/shared/instructions/InstructionSet';
import type { Shader } from '../../renderers/shared/shader/Shader';
import type { Texture } from '../../renderers/shared/texture/Texture';
/**
 * The action types for a batch.
 * @category rendering
 * @advanced
 */
export type BatchAction = 'startBatch' | 'renderBatch';
/**
 * A batch pool is used to store batches when they are not currently in use.
 * @category rendering
 * @advanced
 */
export declare class Batch implements Instruction {
    renderPipeId: string;
    action: BatchAction;
    start: number;
    size: number;
    textures: BatchTextureArray;
    blendMode: BLEND_MODES;
    topology: Topology;
    canBundle: boolean;
    /**
     * breaking rules slightly here in the name of performance..
     * storing references to these bindgroups here is just faster for access!
     * keeps a reference to the GPU bind group to set when rendering this batch for WebGPU. Will be null is using WebGL.
     */
    gpuBindGroup: GPUBindGroup;
    /**
     * breaking rules slightly here in the name of performance..
     * storing references to these bindgroups here is just faster for access!
     * keeps a reference to the bind group to set when rendering this batch for WebGPU. Will be null if using WebGl.
     */
    bindGroup: BindGroup;
    batcher: Batcher;
    /** Elements contained in this batch. Used by the Canvas renderer. */
    elements: BatchableElement[];
    destroy(): void;
}
/**
 * Represents an element that can be batched for rendering.
 * @interface
 * @category rendering
 * @advanced
 */
export interface BatchableElement {
    /**
     * The name of the batcher to use. Must be registered.
     * @type {string}
     */
    batcherName: string;
    /**
     * The texture to be used for rendering.
     * @type {Texture}
     */
    texture: Texture;
    /**
     * The blend mode to be applied.
     * @type {BLEND_MODES}
     */
    blendMode: BLEND_MODES;
    /**
     * The size of the index data.
     * @type {number}
     */
    indexSize: number;
    /**
     * The size of the attribute data.
     * @type {number}
     */
    attributeSize: number;
    /**
     * The topology to be used for rendering.
     * @type {Topology}
     */
    topology: Topology;
    /**
     * Whether the element should be packed as a quad for better performance.
     * @type {boolean}
     */
    packAsQuad: boolean;
    /**
     * The texture ID, stored for efficient updating.
     * @type {number}
     * @private
     */
    _textureId: number;
    /**
     * The starting position in the attribute buffer.
     * @type {number}
     * @private
     */
    _attributeStart: number;
    /**
     * The starting position in the index buffer.
     * @type {number}
     * @private
     */
    _indexStart: number;
    /**
     * Reference to the batcher.
     * @type {Batcher}
     * @private
     */
    _batcher: Batcher;
    /**
     * Reference to the batch.
     * @type {Batch}
     * @private
     */
    _batch: Batch;
}
/**
 * Represents a batchable quad element.
 * @extends BatchableElement
 * @category rendering
 * @advanced
 */
export interface BatchableQuadElement extends BatchableElement {
    /**
     * Indicates that this element should be packed as a quad.
     * @type {true}
     */
    packAsQuad: true;
    /**
     * The size of the attribute data for this quad element.
     * @type {4}
     */
    attributeSize: 4;
    /**
     * The size of the index data for this quad element.
     * @type {6}
     */
    indexSize: 6;
    /**
     * The bounds data for this quad element.
     * @type {BoundsData}
     */
    bounds: BoundsData;
}
/**
 * Represents a batchable mesh element.
 * @extends BatchableElement
 * @category rendering
 * @advanced
 */
export interface BatchableMeshElement extends BatchableElement {
    /**
     * The UV coordinates of the mesh.
     * @type {number[] | Float32Array}
     */
    uvs: number[] | Float32Array;
    /**
     * The vertex positions of the mesh.
     * @type {number[] | Float32Array}
     */
    positions: number[] | Float32Array;
    /**
     * The indices of the mesh.
     * @type {number[] | Uint16Array | Uint32Array}
     */
    indices: number[] | Uint16Array | Uint32Array;
    /**
     * The offset in the index buffer.
     * @type {number}
     */
    indexOffset: number;
    /**
     * The offset in the attribute buffer.
     * @type {number}
     */
    attributeOffset: number;
    /**
     * Indicates that this element should not be packed as a quad.
     * @type {false}
     */
    packAsQuad: false;
}
/**
 * The options for the batcher.
 * @category rendering
 * @advanced
 */
export interface BatcherOptions {
    /** The maximum number of textures per batch. */
    maxTextures: number;
    /** The initial size of the attribute buffer. */
    attributesInitialSize?: number;
    /** The initial size of the index buffer. */
    indicesInitialSize?: number;
}
/**
 * A batcher is used to batch together objects with the same texture.
 * It is an abstract class that must be extended. see DefaultBatcher for an example.
 * @category rendering
 * @advanced
 */
export declare abstract class Batcher {
    static defaultOptions: Partial<BatcherOptions>;
    /** unique id for this batcher */
    readonly uid: number;
    /** The buffer containing attribute data for all elements in the batch. */
    attributeBuffer: ViewableBuffer;
    /** The buffer containing index data for all elements in the batch. */
    indexBuffer: IndexBufferArray;
    /** The current size of the attribute data in the batch. */
    attributeSize: number;
    /** The current size of the index data in the batch. */
    indexSize: number;
    /** The total number of elements currently in the batch. */
    elementSize: number;
    /** The starting index of elements in the current batch. */
    elementStart: number;
    /** Indicates whether the batch data has been modified and needs updating. */
    dirty: boolean;
    /** The current index of the batch being processed. */
    batchIndex: number;
    /** An array of all batches created during the current rendering process. */
    batches: Batch[];
    private _elements;
    private _batchIndexStart;
    private _batchIndexSize;
    /** The maximum number of textures per batch. */
    readonly maxTextures: number;
    /** The name of the batcher. Must be implemented by subclasses. */
    abstract name: string;
    /** The vertex size of the batcher. Must be implemented by subclasses. */
    protected abstract vertexSize: number;
    /** The geometry used by this batcher. Must be implemented by subclasses. */
    abstract geometry: Geometry;
    /**
     * The shader used by this batcher. Must be implemented by subclasses.
     * this can be shared by multiple batchers of the same type.
     */
    abstract shader: Shader;
    /**
     * Packs the attributes of a BatchableMeshElement into the provided views.
     * Must be implemented by subclasses.
     * @param element - The BatchableMeshElement to pack.
     * @param float32View - The Float32Array view to pack into.
     * @param uint32View - The Uint32Array view to pack into.
     * @param index - The starting index in the views.
     * @param textureId - The texture ID to use.
     */
    abstract packAttributes(element: BatchableMeshElement, float32View: Float32Array, uint32View: Uint32Array, index: number, textureId: number): void;
    /**
     * Packs the attributes of a BatchableQuadElement into the provided views.
     * Must be implemented by subclasses.
     * @param element - The BatchableQuadElement to pack.
     * @param float32View - The Float32Array view to pack into.
     * @param uint32View - The Uint32Array view to pack into.
     * @param index - The starting index in the views.
     * @param textureId - The texture ID to use.
     */
    abstract packQuadAttributes(element: BatchableQuadElement, float32View: Float32Array, uint32View: Uint32Array, index: number, textureId: number): void;
    constructor(options: BatcherOptions);
    begin(): void;
    add(batchableObject: BatchableElement): void;
    checkAndUpdateTexture(batchableObject: BatchableElement, texture: Texture): boolean;
    updateElement(batchableObject: BatchableElement): void;
    /**
     * breaks the batcher. This happens when a batch gets too big,
     * or we need to switch to a different type of rendering (a filter for example)
     * @param instructionSet
     */
    break(instructionSet: InstructionSet): void;
    private _finishBatch;
    finish(instructionSet: InstructionSet): void;
    /**
     * Resizes the attribute buffer to the given size (1 = 1 float32)
     * @param size - the size in vertices to ensure (not bytes!)
     */
    ensureAttributeBuffer(size: number): void;
    /**
     * Resizes the index buffer to the given size (1 = 1 float32)
     * @param size - the size in vertices to ensure (not bytes!)
     */
    ensureIndexBuffer(size: number): void;
    private _resizeAttributeBuffer;
    private _resizeIndexBuffer;
    packQuadIndex(indexBuffer: IndexBufferArray, index: number, indicesOffset: number): void;
    packIndex(element: BatchableMeshElement, indexBuffer: IndexBufferArray, index: number, indicesOffset: number): void;
    /**
     * Destroys the batch and its resources.
     * @param options - destruction options
     * @param options.shader - whether to destroy the associated shader
     */
    destroy(options?: {
        shader?: boolean;
    }): void;
}
