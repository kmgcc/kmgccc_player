import { TextureSource } from '../rendering/renderers/shared/texture/sources/TextureSource.mjs';
import { Texture } from '../rendering/renderers/shared/texture/Texture.mjs';
import { Container } from '../scene/container/Container.mjs';
import { Graphics } from '../scene/graphics/shared/Graphics.mjs';
import { GraphicsContext } from '../scene/graphics/shared/GraphicsContext.mjs';
import { Mesh } from '../scene/mesh/shared/Mesh.mjs';
import { Sprite } from '../scene/sprite/Sprite.mjs';
import { AnimatedSprite } from '../scene/sprite-animated/AnimatedSprite.mjs';
import { TilingSprite } from '../scene/sprite-tiling/TilingSprite.mjs';
import { Text } from '../scene/text/Text.mjs';
import { PrepareBase } from './PrepareBase.mjs';

"use strict";
class PrepareQueue extends PrepareBase {
  /**
   * Resolve the given resource type and return an item for the queue
   * @param source
   * @param queue
   */
  resolveQueueItem(source, queue) {
    if (source instanceof Container) {
      this.resolveContainerQueueItem(source, queue);
    } else if (source instanceof TextureSource || source instanceof Texture) {
      queue.push(source.source);
    } else if (source instanceof GraphicsContext) {
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
    if (container instanceof Sprite || container instanceof TilingSprite || container instanceof Mesh) {
      queue.push(container.texture.source);
    } else if (container instanceof Text) {
      queue.push(container);
    } else if (container instanceof Graphics) {
      queue.push(container.context);
    } else if (container instanceof AnimatedSprite) {
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

export { PrepareQueue };
//# sourceMappingURL=PrepareQueue.mjs.map
