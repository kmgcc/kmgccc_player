import { Container } from '../scene/container/Container';
import type { TextureSource } from '../rendering/renderers/shared/texture/sources/TextureSource';
import type { Texture } from '../rendering/renderers/shared/texture/Texture';
import type { Renderer } from '../rendering/renderers/types';
import type { GraphicsContext } from '../scene/graphics/shared/GraphicsContext';
import type { Text } from '../scene/text/Text';
/**
 * The accepted types to pass to the prepare system
 * @category rendering
 * @advanced
 */
export type PrepareSourceItem = Container | TextureSource | Texture | GraphicsContext;
/**
 * The valid types resolved to the queue ready for upload
 * @category rendering
 * @advanced
 */
export type PrepareQueueItem = TextureSource | Text | GraphicsContext;
/**
 * Part of the prepare system. Responsible for uploading all the items to the GPU.
 * This class provides the base functionality and handles processing the queue asynchronously.
 * @category rendering
 * @advanced
 */
export declare abstract class PrepareBase {
    /** The number of uploads to process per frame */
    static uploadsPerFrame: number;
    /** Reference to the renderer */
    protected renderer: Renderer;
    /** The queue to process over a async timer */
    protected queue: PrepareQueueItem[];
    /** Collection of callbacks to call when the uploads are finished */
    protected resolves: ((value: void | PromiseLike<void>) => void)[];
    /** Timeout id for next processing call */
    protected timeout?: number;
    private _destroyed;
    /**
     * @param {Renderer} renderer - A reference to the current renderer
     */
    constructor(renderer: Renderer);
    /** Resolve the given resource type and return an item for the queue */
    protected abstract resolveQueueItem(source: PrepareSourceItem, queue: PrepareQueueItem[]): void;
    protected abstract uploadQueueItem(item: PrepareQueueItem): void;
    /**
     * Return a copy of the queue
     * @returns {PrepareQueueItem[]} The queue
     */
    getQueue(): PrepareQueueItem[];
    /**
     * Add a textures or graphics resource to the queue
     * @param {PrepareSourceItem | PrepareSourceItem[]} resource
     */
    add(resource: PrepareSourceItem | PrepareSourceItem[]): this;
    /**
     * Recursively add a container and its children to the queue
     * @param {Container} container - The container to add to the queue
     */
    private _addContainer;
    /**
     * Upload all the textures and graphics to the GPU (optionally add more resources to the queue first)
     * @param {PrepareSourceItem | PrepareSourceItem[] | undefined} resource
     */
    upload(resource?: PrepareSourceItem | PrepareSourceItem[]): Promise<void>;
    /** eliminate duplicates before processing */
    dedupeQueue(): void;
    destroy(): void;
    /** called per frame by the ticker, defer processing to next tick */
    private readonly _tick;
    /** process the queue up to max item limit per frame */
    private readonly _processQueue;
    /** Call all the resolve callbacks */
    private _resolve;
}
