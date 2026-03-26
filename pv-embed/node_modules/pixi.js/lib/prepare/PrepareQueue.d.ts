import { Container } from '../scene/container/Container';
import { GraphicsContext } from '../scene/graphics/shared/GraphicsContext';
import { PrepareBase } from './PrepareBase';
import type { PrepareQueueItem, PrepareSourceItem } from './PrepareBase';
/**
 * Part of the prepare system. Responsible for uploading all the items to the GPU.
 * This class extends the base functionality and resolves given resource items ready for the queue.
 * @category rendering
 * @advanced
 */
export declare abstract class PrepareQueue extends PrepareBase {
    /**
     * Resolve the given resource type and return an item for the queue
     * @param source
     * @param queue
     */
    protected resolveQueueItem(source: PrepareSourceItem, queue: PrepareQueueItem[]): void;
    /**
     * Resolve the given container and return an item for the queue
     * @param container
     * @param queue
     */
    protected resolveContainerQueueItem(container: Container, queue: PrepareQueueItem[]): void;
    /**
     * Resolve the given graphics context and return an item for the queue
     * @param graphicsContext
     */
    protected resolveGraphicsContextQueueItem(graphicsContext: GraphicsContext): PrepareQueueItem | null;
}
