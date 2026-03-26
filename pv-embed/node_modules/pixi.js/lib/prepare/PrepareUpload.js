'use strict';

var TextureSource = require('../rendering/renderers/shared/texture/sources/TextureSource.js');
var GraphicsContext = require('../scene/graphics/shared/GraphicsContext.js');
var Text = require('../scene/text/Text.js');
var BitmapText = require('../scene/text-bitmap/BitmapText.js');
var HTMLText = require('../scene/text-html/HTMLText.js');
var PrepareQueue = require('./PrepareQueue.js');

"use strict";
class PrepareUpload extends PrepareQueue.PrepareQueue {
  /**
   * Upload the given queue item
   * @param item
   */
  uploadQueueItem(item) {
    if (item instanceof TextureSource.TextureSource) {
      this.uploadTextureSource(item);
    } else if (item instanceof Text.Text) {
      this.uploadText(item);
    } else if (item instanceof HTMLText.HTMLText) {
      this.uploadHTMLText(item);
    } else if (item instanceof BitmapText.BitmapText) {
      this.uploadBitmapText(item);
    } else if (item instanceof GraphicsContext.GraphicsContext) {
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

exports.PrepareUpload = PrepareUpload;
//# sourceMappingURL=PrepareUpload.js.map
