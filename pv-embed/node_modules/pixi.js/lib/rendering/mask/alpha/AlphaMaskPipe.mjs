import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { FilterEffect } from '../../../filters/FilterEffect.mjs';
import { MaskFilter } from '../../../filters/mask/MaskFilter.mjs';
import { Bounds } from '../../../scene/container/bounds/Bounds.mjs';
import { getGlobalBounds } from '../../../scene/container/bounds/getGlobalBounds.mjs';
import { Sprite } from '../../../scene/sprite/Sprite.mjs';
import { BigPool } from '../../../utils/pool/PoolGroup.mjs';
import { Texture } from '../../renderers/shared/texture/Texture.mjs';
import { TexturePool } from '../../renderers/shared/texture/TexturePool.mjs';
import { RendererType } from '../../renderers/types.mjs';

"use strict";
const tempBounds = new Bounds();
class AlphaMaskEffect extends FilterEffect {
  constructor() {
    super();
    this.filters = [new MaskFilter({
      sprite: new Sprite(Texture.EMPTY),
      inverse: false,
      resolution: "inherit",
      antialias: "inherit"
    })];
  }
  get sprite() {
    return this.filters[0].sprite;
  }
  set sprite(value) {
    this.filters[0].sprite = value;
  }
  get inverse() {
    return this.filters[0].inverse;
  }
  set inverse(value) {
    this.filters[0].inverse = value;
  }
}
class AlphaMaskPipe {
  constructor(renderer) {
    this._activeMaskStage = [];
    this._renderer = renderer;
  }
  push(mask, maskedContainer, instructionSet) {
    const renderer = this._renderer;
    renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add({
      renderPipeId: "alphaMask",
      action: "pushMaskBegin",
      mask,
      inverse: maskedContainer._maskOptions.inverse,
      canBundle: false,
      maskedContainer
    });
    mask.inverse = maskedContainer._maskOptions.inverse;
    if (mask.renderMaskToTexture) {
      const maskContainer = mask.mask;
      maskContainer.includeInBuild = true;
      maskContainer.collectRenderables(
        instructionSet,
        renderer,
        null
      );
      maskContainer.includeInBuild = false;
    }
    renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add({
      renderPipeId: "alphaMask",
      action: "pushMaskEnd",
      mask,
      maskedContainer,
      inverse: maskedContainer._maskOptions.inverse,
      canBundle: false
    });
  }
  pop(mask, _maskedContainer, instructionSet) {
    const renderer = this._renderer;
    renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add({
      renderPipeId: "alphaMask",
      action: "popMaskEnd",
      mask,
      inverse: _maskedContainer._maskOptions.inverse,
      canBundle: false
    });
  }
  execute(instruction) {
    const renderer = this._renderer;
    const renderMask = instruction.mask.renderMaskToTexture;
    if (instruction.action === "pushMaskBegin") {
      const filterEffect = BigPool.get(AlphaMaskEffect);
      filterEffect.inverse = instruction.inverse;
      if (renderMask) {
        instruction.mask.mask.measurable = true;
        const bounds = getGlobalBounds(instruction.mask.mask, true, tempBounds);
        instruction.mask.mask.measurable = false;
        bounds.ceil();
        const colorTextureSource = renderer.renderTarget.renderTarget.colorTexture.source;
        const filterTexture = TexturePool.getOptimalTexture(
          bounds.width,
          bounds.height,
          colorTextureSource._resolution,
          colorTextureSource.antialias
        );
        renderer.renderTarget.push(filterTexture, true);
        renderer.globalUniforms.push({
          offset: bounds,
          worldColor: 4294967295
        });
        const sprite = filterEffect.sprite;
        sprite.texture = filterTexture;
        sprite.worldTransform.tx = bounds.minX;
        sprite.worldTransform.ty = bounds.minY;
        this._activeMaskStage.push({
          filterEffect,
          maskedContainer: instruction.maskedContainer,
          filterTexture
        });
      } else {
        filterEffect.sprite = instruction.mask.mask;
        this._activeMaskStage.push({
          filterEffect,
          maskedContainer: instruction.maskedContainer
        });
      }
    } else if (instruction.action === "pushMaskEnd") {
      const maskData = this._activeMaskStage[this._activeMaskStage.length - 1];
      if (renderMask) {
        if (renderer.type === RendererType.WEBGL) {
          renderer.renderTarget.finishRenderPass();
        }
        renderer.renderTarget.pop();
        renderer.globalUniforms.pop();
      }
      renderer.filter.push({
        renderPipeId: "filter",
        action: "pushFilter",
        container: maskData.maskedContainer,
        filterEffect: maskData.filterEffect,
        canBundle: false
      });
    } else if (instruction.action === "popMaskEnd") {
      renderer.filter.pop();
      const maskData = this._activeMaskStage.pop();
      if (renderMask) {
        TexturePool.returnTexture(maskData.filterTexture);
      }
      BigPool.return(maskData.filterEffect);
    }
  }
  destroy() {
    this._renderer = null;
    this._activeMaskStage = null;
  }
}
/** @ignore */
AlphaMaskPipe.extension = {
  type: [
    ExtensionType.WebGLPipes,
    ExtensionType.WebGPUPipes,
    ExtensionType.CanvasPipes
  ],
  name: "alphaMask"
};

export { AlphaMaskPipe };
//# sourceMappingURL=AlphaMaskPipe.mjs.map
