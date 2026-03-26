'use strict';

var TextureSource = require('../rendering/renderers/shared/texture/sources/TextureSource.js');
var Texture = require('../rendering/renderers/shared/texture/Texture.js');
var Container = require('../scene/container/Container.js');
var Graphics = require('../scene/graphics/shared/Graphics.js');
var GraphicsContext = require('../scene/graphics/shared/GraphicsContext.js');
var Mesh = require('../scene/mesh/shared/Mesh.js');
var Sprite = require('../scene/sprite/Sprite.js');
var AnimatedSprite = require('../scene/sprite-animated/AnimatedSprite.js');
var TilingSprite = require('../scene/sprite-tiling/TilingSprite.js');
var Text = require('../scene/text/Text.js');
var PrepareBase = require('./PrepareBase.js');

"use strict";
class PrepareQueue extends PrepareBase.PrepareBase {
  /**
   * Resolve the given resource type and return an item for the queue
   * @param source
   * @param queue
   */
  resolveQueueItem(source, queue) {
    if (source instanceof Container.Container) {
      this.resolveContainerQueueItem(source, queue);
    } else if (source instanceof TextureSource.TextureSource || source instanceof Texture.Texture) {
      queue.push(source.source);
    } else if (source instanceof GraphicsContext.GraphicsContext) {
      queue.push(source);
    }
    return null;
  }
  /**
   * Resolve the given container and return an item for the queue
   * @param container
   * @param queue
   */
  resolveContainerQueueItem(container, queue) {
    if (container instanceof Sprite.Sprite || container instanceof TilingSprite.TilingSprite || container instanceof Mesh.Mesh) {
      queue.push(container.texture.source);
    } else if (container instanceof Text.Text) {
      queue.push(container);
    } else if (container instanceof Graphics.Graphics) {
      queue.push(container.context);
    } else if (container instanceof AnimatedSprite.AnimatedSprite) {
      container.textures.forEach((textureOrFrame) => {
        if (textureOrFrame.source) {
          queue.push(textureOrFrame.source);
        } else {
          queue.push(textureOrFrame.texture.source);
        }
      });
    }
  }
  /**
   * Resolve the given graphics context and return an item for the queue
   * @param graphicsContext
   */
  resolveGraphicsContextQueueItem(graphicsContext) {
    this.renderer.graphicsContext.getGpuContext(graphicsContext);
    const { instructions } = graphicsContext;
    for (const instruction of instructions) {
      if (instruction.action === "texture") {
        const { image } = instruction.data;
        return image.source;
      } else if (instruction.action === "fill") {
        const { texture } = instruction.data.style;
        return texture.source;
      }
    }
    return null;
  }
}

exports.PrepareQueue = PrepareQueue;
//# sourceMappingURL=PrepareQueue.js.map
