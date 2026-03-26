import { TextureSource } from '../rendering/renderers/shared/texture/sources/TextureSource.mjs';
import { GraphicsContext } from '../scene/graphics/shared/GraphicsContext.mjs';
import { Text } from '../scene/text/Text.mjs';
import { BitmapText } from '../scene/text-bitmap/BitmapText.mjs';
import { HTMLText } from '../scene/text-html/HTMLText.mjs';
import { PrepareQueue } from './PrepareQueue.mjs';

"use strict";
class PrepareUpload extends PrepareQueue {
  /**
   * Upload the given queue item
   * @param item
   */
  uploadQueueItem(item) {
    if (item instanceof TextureSource) {
      this.uploadTextureSource(item);
    } else if (item instanceof Text) {
      this.uploadText(item);
    } else if (item instanceof HTMLText) {
      this.uploadHTMLText(item);
    } else if (item instanceof BitmapText) {
      this.uploadBitmapText(item);
    } else if (item instanceof GraphicsContext) {
      this.uploadGraphicsContext(item);
    }
  }
  uploadTextureSource(textureSource) {
    this.renderer.texture.initSource(textureSource);
  }
  uploadText(_text) {
    this.renderer.renderPipes.text.initGpuText(_text);
  }
  uploadBitmapText(_text) {
    this.renderer.renderPipes.bitmapText.initGpuText(_text);
  }
  uploadHTMLText(_text) {
    this.renderer.renderPipes.htmlText.initGpuText(_text);
  }
  /**
   * Resolve the given graphics context and return an item for the queue
   * @param graphicsContext
   */
  uploadGraphicsContext(graphicsContext) {
    this.renderer.graphicsContext.getGpuContext(graphicsContext);
    const { instructions } = graphicsContext;
    for (const instruction of instructions) {
      if (instruction.action === "texture") {
        const { image } = instruction.data;
        this.uploadTextureSource(image.source);
      } else if (instruction.action === "fill") {
        const { texture } = instruction.data.style;
        this.uploadTextureSource(texture.source);
      }
    }
    return null;
  }
}

export { PrepareUpload };
//# sourceMappingURL=PrepareUpload.mjs.map
