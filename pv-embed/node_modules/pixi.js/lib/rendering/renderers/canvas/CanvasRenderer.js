'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var CustomRenderPipe = require('../../../scene/container/CustomRenderPipe.js');
var RenderGroupPipe = require('../../../scene/container/RenderGroupPipe.js');
var CanvasGraphicsAdaptor = require('../../../scene/graphics/canvas/CanvasGraphicsAdaptor.js');
var SpritePipe = require('../../../scene/sprite/SpritePipe.js');
var CanvasBatchAdaptor = require('../../batcher/canvas/CanvasBatchAdaptor.js');
var BatcherPipe = require('../../batcher/shared/BatcherPipe.js');
var AlphaMaskPipe = require('../../mask/alpha/AlphaMaskPipe.js');
var CanvasColorMaskPipe = require('../../mask/color/CanvasColorMaskPipe.js');
var CanvasStencilMaskPipe = require('../../mask/stencil/CanvasStencilMaskPipe.js');
var BlendModePipe = require('../shared/blendModes/BlendModePipe.js');
var AbstractRenderer = require('../shared/system/AbstractRenderer.js');
var SharedSystems = require('../shared/system/SharedSystems.js');
var types = require('../types.js');
var CanvasContextSystem = require('./CanvasContextSystem.js');
var CanvasLimitsSystem = require('./CanvasLimitsSystem.js');
var CanvasRenderTargetSystem = require('./renderTarget/CanvasRenderTargetSystem.js');
var CanvasTextureSystem = require('./texture/CanvasTextureSystem.js');

"use strict";
const DefaultCanvasSystems = [
  ...SharedSystems.SharedSystems,
  CanvasContextSystem.CanvasContextSystem,
  CanvasLimitsSystem.CanvasLimitsSystem,
  CanvasTextureSystem.CanvasTextureSystem,
  CanvasRenderTargetSystem.CanvasRenderTargetSystem
];
const DefaultCanvasPipes = [
  BlendModePipe.BlendModePipe,
  BatcherPipe.BatcherPipe,
  SpritePipe.SpritePipe,
  RenderGroupPipe.RenderGroupPipe,
  AlphaMaskPipe.AlphaMaskPipe,
  CanvasStencilMaskPipe.CanvasStencilMaskPipe,
  CanvasColorMaskPipe.CanvasColorMaskPipe,
  CustomRenderPipe.CustomRenderPipe
];
const DefaultCanvasAdapters = [
  CanvasBatchAdaptor.CanvasBatchAdaptor,
  CanvasGraphicsAdaptor.CanvasGraphicsAdaptor
];
const systems = [];
const renderPipes = [];
const renderPipeAdaptors = [];
Extensions.extensions.handleByNamedList(Extensions.ExtensionType.CanvasSystem, systems);
Extensions.extensions.handleByNamedList(Extensions.ExtensionType.CanvasPipes, renderPipes);
Extensions.extensions.handleByNamedList(Extensions.ExtensionType.CanvasPipesAdaptor, renderPipeAdaptors);
Extensions.extensions.add(...DefaultCanvasSystems, ...DefaultCanvasPipes, ...DefaultCanvasAdapters);
class CanvasRenderer extends AbstractRenderer.AbstractRenderer {
  constructor() {
    const systemConfig = {
      name: "canvas",
      type: types.RendererType.CANVAS,
      systems,
      renderPipes,
      renderPipeAdaptors
    };
    super(systemConfig);
  }
}

exports.CanvasRenderer = CanvasRenderer;
//# sourceMappingURL=CanvasRenderer.js.map
