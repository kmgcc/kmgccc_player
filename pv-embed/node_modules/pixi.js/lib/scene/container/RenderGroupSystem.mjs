import { ExtensionType } from '../../extensions/Extensions.mjs';
import { Matrix } from '../../maths/matrix/Matrix.mjs';
import { TexturePool } from '../../rendering/renderers/shared/texture/TexturePool.mjs';
import { TextureStyle } from '../../rendering/renderers/shared/texture/TextureStyle.mjs';
import { Bounds } from './bounds/Bounds.mjs';
import { clearList } from './utils/clearList.mjs';
import { executeInstructions } from './utils/executeInstructions.mjs';
import { updateRenderGroupTransforms } from './utils/updateRenderGroupTransforms.mjs';
import { validateRenderables } from './utils/validateRenderables.mjs';

"use strict";
const tempMatrix = new Matrix();
class RenderGroupSystem {
  constructor(renderer) {
    this._renderer = renderer;
  }
  render({ container, transform }) {
    const parent = container.parent;
    const renderGroupParent = container.renderGroup.renderGroupParent;
    container.parent = null;
    container.renderGroup.renderGroupParent = null;
    const renderer = this._renderer;
    const originalLocalTransform = tempMatrix;
    if (transform) {
      originalLocalTransform.copyFrom(container.renderGroup.localTransform);
      container.renderGroup.localTransform.copyFrom(transform);
    }
    const renderPipes = renderer.renderPipes;
    this._updateCachedRenderGroups(container.renderGroup, null);
    this._updateRenderGroups(container.renderGroup);
    renderer.globalUniforms.start({
      worldTransformMatrix: transform ? container.renderGroup.localTransform : container.renderGroup.worldTransform,
      worldColor: container.renderGroup.worldColorAlpha
    });
    executeInstructions(container.renderGroup, renderPipes);
    if (renderPipes.uniformBatch) {
      renderPipes.uniformBatch.renderEnd();
    }
    if (transform) {
      container.renderGroup.localTransform.copyFrom(originalLocalTransform);
    }
    container.parent = parent;
    container.renderGroup.renderGroupParent = renderGroupParent;
  }
  destroy() {
    this._renderer = null;
  }
  _updateCachedRenderGroups(renderGroup, closestCacheAsTexture) {
    renderGroup._parentCacheAsTextureRenderGroup = closestCacheAsTexture;
    if (renderGroup.isCachedAsTexture) {
      if (!renderGroup.textureNeedsUpdate) return;
      closestCacheAsTexture = renderGroup;
    }
    for (let i = renderGroup.renderGroupChildren.length - 1; i >= 0; i--) {
      this._updateCachedRenderGroups(renderGroup.renderGroupChildren[i], closestCacheAsTexture);
    }
    renderGroup.invalidateMatrices();
    if (renderGroup.isCachedAsTexture) {
      if (renderGroup.textureNeedsUpdate) {
        const bounds = renderGroup.root.getLocalBounds();
        const renderer = this._renderer;
        const resolution = renderGroup.textureOptions.resolution || renderer.view.resolution;
        const antialias = renderGroup.textureOptions.antialias ?? renderer.view.antialias;
        const scaleMode = renderGroup.textureOptions.scaleMode ?? "linear";
        const lastTexture = renderGroup.texture;
        bounds.ceil();
        if (renderGroup.texture) {
          TexturePool.returnTexture(renderGroup.texture, true);
        }
        const texture = TexturePool.getOptimalTexture(
          bounds.width,
          bounds.height,
          resolution,
          antialias
        );
        texture._source.style = new TextureStyle({ scaleMode });
        renderGroup.texture = texture;
        renderGroup._textureBounds || (renderGroup._textureBounds = new Bounds());
        renderGroup._textureBounds.copyFrom(bounds);
        if (lastTexture !== renderGroup.texture) {
          if (renderGroup.renderGroupParent) {
            renderGroup.renderGroupParent.structureDidChange = true;
          }
        }
      }
    } else if (renderGroup.texture) {
      TexturePool.returnTexture(renderGroup.texture, true);
      renderGroup.texture = null;
    }
  }
  _updateRenderGroups(renderGroup) {
    const renderer = this._renderer;
    const renderPipes = renderer.renderPipes;
    renderGroup.runOnRender(renderer);
    renderGroup.instructionSet.renderPipes = renderPipes;
    if (!renderGroup.structureDidChange) {
      validateRenderables(renderGroup, renderPipes);
    } else {
      clearList(renderGroup.childrenRenderablesToUpdate.list, 0);
    }
    updateRenderGroupTransforms(renderGroup);
    if (renderGroup.structureDidChange) {
      renderGroup.structureDidChange = false;
      this._buildInstructions(renderGroup, renderer);
    } else {
      this._updateRenderables(renderGroup);
    }
    renderGroup.childrenRenderablesToUpdate.index = 0;
    renderer.renderPipes.batch.upload(renderGroup.instructionSet);
    if (renderGroup.isCachedAsTexture && !renderGroup.textureNeedsUpdate) return;
    for (let i = 0; i < renderGroup.renderGroupChildren.length; i++) {
      this._updateRenderGroups(renderGroup.renderGroupChildren[i]);
    }
  }
  _updateRenderables(renderGroup) {
    const { list, index } = renderGroup.childrenRenderablesToUpdate;
    for (let i = 0; i < index; i++) {
      const container = list[i];
      if (container.didViewUpdate) {
        renderGroup.updateRenderable(container);
      }
    }
    clearList(list, index);
  }
  _buildInstructions(renderGroup, rendererOrPipes) {
    const root = renderGroup.root;
    const instructionSet = renderGroup.instructionSet;
    instructionSet.reset();
    const renderer = rendererOrPipes.renderPipes ? rendererOrPipes : rendererOrPipes.batch.renderer;
    const renderPipes = renderer.renderPipes;
    renderPipes.batch.buildStart(instructionSet);
    renderPipes.blendMode.buildStart();
    renderPipes.colorMask.buildStart();
    if (root.sortableChildren) {
      root.sortChildren();
    }
    root.collectRenderablesWithEffects(instructionSet, renderer, null);
    renderPipes.batch.buildEnd(instructionSet);
    renderPipes.blendMode.buildEnd(instructionSet);
  }
}
/** @ignore */
RenderGroupSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem,
    ExtensionType.CanvasSystem
  ],
  name: "renderGroup"
};

export { RenderGroupSystem };
//# sourceMappingURL=RenderGroupSystem.mjs.map
