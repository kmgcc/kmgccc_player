'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var FilterEffect = require('../../../filters/FilterEffect.js');
var MaskFilter = require('../../../filters/mask/MaskFilter.js');
var Bounds = require('../../../scene/container/bounds/Bounds.js');
var getGlobalBounds = require('../../../scene/container/bounds/getGlobalBounds.js');
var Sprite = require('../../../scene/sprite/Sprite.js');
var PoolGroup = require('../../../utils/pool/PoolGroup.js');
var Texture = require('../../renderers/shared/texture/Texture.js');
var TexturePool = require('../../renderers/shared/texture/TexturePool.js');
var types = require('../../renderers/types.js');

"use strict";
const tempBounds = new Bounds.Bounds();
class AlphaMaskEffect extends FilterEffect.FilterEffect {
  constructor() {
    super();
    this.filters = [new MaskFilter.MaskFilter({
      sprite: new Sprite.Sprite(Texture.Texture.EMPTY),
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
      const filterEffect = PoolGroup.BigPool.get(AlphaMaskEffect);
      filterEffect.inverse = instruction.inverse;
      if (renderMask) {
        instruction.mask.mask.measurable = true;
        const bounds = getGlobalBounds.getGlobalBounds(instruction.mask.mask, true, tempBounds);
        instruction.mask.mask.measurable = false;
        bounds.ceil();
        const colorTextureSource = renderer.renderTarget.renderTarget.colorTexture.source;
        const filterTexture = TexturePool.TexturePool.getOptimalTexture(
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
        if (renderer.type === types.RendererType.WEBGL) {
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
        TexturePool.TexturePool.returnTexture(maskData.filterTexture);
      }
      PoolGroup.BigPool.return(maskData.filterEffect);
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
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes,
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "alphaMask"
};

exports.AlphaMaskPipe = AlphaMaskPipe;
//# sourceMappingURL=AlphaMaskPipe.js.map
