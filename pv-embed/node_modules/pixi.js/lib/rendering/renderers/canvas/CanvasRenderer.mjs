import { extensions, ExtensionType } from '../../../extensions/Extensions.mjs';
import { CustomRenderPipe } from '../../../scene/container/CustomRenderPipe.mjs';
import { RenderGroupPipe } from '../../../scene/container/RenderGroupPipe.mjs';
import { CanvasGraphicsAdaptor } from '../../../scene/graphics/canvas/CanvasGraphicsAdaptor.mjs';
import { SpritePipe } from '../../../scene/sprite/SpritePipe.mjs';
import { CanvasBatchAdaptor } from '../../batcher/canvas/CanvasBatchAdaptor.mjs';
import { BatcherPipe } from '../../batcher/shared/BatcherPipe.mjs';
import { AlphaMaskPipe } from '../../mask/alpha/AlphaMaskPipe.mjs';
import { CanvasColorMaskPipe } from '../../mask/color/CanvasColorMaskPipe.mjs';
import { CanvasStencilMaskPipe } from '../../mask/stencil/CanvasStencilMaskPipe.mjs';
import { BlendModePipe } from '../shared/blendModes/BlendModePipe.mjs';
import { AbstractRenderer } from '../shared/system/AbstractRenderer.mjs';
import { SharedSystems } from '../shared/system/SharedSystems.mjs';
import { RendererType } from '../types.mjs';
import { CanvasContextSystem } from './CanvasContextSystem.mjs';
import { CanvasLimitsSystem } from './CanvasLimitsSystem.mjs';
import { CanvasRenderTargetSystem } from './renderTarget/CanvasRenderTargetSystem.mjs';
import { CanvasTextureSystem } from './texture/CanvasTextureSystem.mjs';

"use strict";
const DefaultCanvasSystems = [
  ...SharedSystems,
  CanvasContextSystem,
  CanvasLimitsSystem,
  CanvasTextureSystem,
  CanvasRenderTargetSystem
];
const DefaultCanvasPipes = [
  BlendModePipe,
  BatcherPipe,
  SpritePipe,
  RenderGroupPipe,
  AlphaMaskPipe,
  CanvasStencilMaskPipe,
  CanvasColorMaskPipe,
  CustomRenderPipe
];
const DefaultCanvasAdapters = [
  CanvasBatchAdaptor,
  CanvasGraphicsAdaptor
];
const systems = [];
const renderPipes = [];
const renderPipeAdaptors = [];
extensions.handleByNamedList(ExtensionType.CanvasSystem, systems);
extensions.handleByNamedList(ExtensionType.CanvasPipes, renderPipes);
extensions.handleByNamedList(ExtensionType.CanvasPipesAdaptor, renderPipeAdaptors);
extensions.add(...DefaultCanvasSystems, ...DefaultCanvasPipes, ...DefaultCanvasAdapters);
class CanvasRenderer extends AbstractRenderer {
  constructor() {
    const systemConfig = {
      name: "canvas",
      type: RendererType.CANVAS,
      systems,
      renderPipes,
      renderPipeAdaptors
    };
    super(systemConfig);
  }
}

export { CanvasRenderer };
//# sourceMappingURL=CanvasRenderer.mjs.map
