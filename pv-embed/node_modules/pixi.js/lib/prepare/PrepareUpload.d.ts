import { TextureSource } from '../rendering/renderers/shared/texture/sources/TextureSource';
import { GraphicsContext } from '../scene/graphics/shared/GraphicsContext';
import { Text } from '../scene/text/Text';
import { BitmapText } from '../scene/text-bitmap/BitmapText';
import { HTMLText } from '../scene/text-html/HTMLText';
import { PrepareQueue } from './PrepareQueue';
import type { PrepareQueueItem } from './PrepareBase';
/**
 * @advanced
 * Part of the prepare system. Responsible for uploading all the items to the GPU.
 * This class extends the resolver functionality and uploads the given queue items.
 * @category rendering
 */
export declare abstract class PrepareUpload extends PrepareQueue {
    /**
     * Upload the given queue item
     * @param item
     */
    protected uploadQueueItem(item: PrepareQueueItem): void;
    protected uploadTextureSource(textureSource: TextureSource): void;
    protected uploadText(_text: Text): void;
    protected uploadBitmapText(_text: BitmapText): void;
    protected uploadHTMLText(_text: HTMLText): void;
    /**
     * Resolve the given graphics context and return an item for the queue
     * @param graphicsContext
     */
    protected uploadGraphicsContext(graphicsContext: GraphicsContext): void;
}
