import { extensions, ExtensionType } from '../../../extensions/Extensions.mjs';
import { GlGraphicsAdaptor } from '../../../scene/graphics/gl/GlGraphicsAdaptor.mjs';
import { GlMeshAdaptor } from '../../../scene/mesh/gl/GlMeshAdaptor.mjs';
import { GlBatchAdaptor } from '../../batcher/gl/GlBatchAdaptor.mjs';
import { AbstractRenderer } from '../shared/system/AbstractRenderer.mjs';
import { SharedSystems, SharedRenderPipes } from '../shared/system/SharedSystems.mjs';
import { RendererType } from '../types.mjs';
import { GlBufferSystem } from './buffer/GlBufferSystem.mjs';
import { GlContextSystem } from './context/GlContextSystem.mjs';
import { GlGeometrySystem } from './geometry/GlGeometrySystem.mjs';
import { GlBackBufferSystem } from './GlBackBufferSystem.mjs';
import { GlColorMaskSystem } from './GlColorMaskSystem.mjs';
import { GlEncoderSystem } from './GlEncoderSystem.mjs';
import { GlLimitsSystem } from './GlLimitsSystem.mjs';
import { GlStencilSystem } from './GlStencilSystem.mjs';
import { GlUboSystem } from './GlUboSystem.mjs';
import { GlRenderTargetSystem } from './renderTarget/GlRenderTargetSystem.mjs';
import { GlShaderSystem } from './shader/GlShaderSystem.mjs';
import { GlUniformGroupSystem } from './shader/GlUniformGroupSystem.mjs';
import { GlStateSystem } from './state/GlStateSystem.mjs';
import { GlTextureSystem } from './texture/GlTextureSystem.mjs';

"use strict";
const DefaultWebGLSystems = [
  ...SharedSystems,
  GlUboSystem,
  GlBackBufferSystem,
  GlContextSystem,
  GlLimitsSystem,
  GlBufferSystem,
  GlTextureSystem,
  GlRenderTargetSystem,
  GlGeometrySystem,
  GlUniformGroupSystem,
  GlShaderSystem,
  GlEncoderSystem,
  GlStateSystem,
  GlStencilSystem,
  GlColorMaskSystem
];
const DefaultWebGLPipes = [...SharedRenderPipes];
const DefaultWebGLAdapters = [GlBatchAdaptor, GlMeshAdaptor, GlGraphicsAdaptor];
const systems = [];
const renderPipes = [];
const renderPipeAdaptors = [];
extensions.handleByNamedList(ExtensionType.WebGLSystem, systems);
extensions.handleByNamedList(ExtensionType.WebGLPipes, renderPipes);
extensions.handleByNamedList(ExtensionType.WebGLPipesAdaptor, renderPipeAdaptors);
extensions.add(...DefaultWebGLSystems, ...DefaultWebGLPipes, ...DefaultWebGLAdapters);
class WebGLRenderer extends AbstractRenderer {
  constructor() {
    const systemConfig = {
      name: "webgl",
      type: RendererType.WEBGL,
      systems,
      renderPipes,
      renderPipeAdaptors
    };
    super(systemConfig);
  }
}

export { WebGLRenderer };
//# sourceMappingURL=WebGLRenderer.mjs.map
