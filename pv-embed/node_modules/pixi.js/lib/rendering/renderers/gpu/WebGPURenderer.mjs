import { extensions, ExtensionType } from '../../../extensions/Extensions.mjs';
import { GpuGraphicsAdaptor } from '../../../scene/graphics/gpu/GpuGraphicsAdaptor.mjs';
import { GpuMeshAdapter } from '../../../scene/mesh/gpu/GpuMeshAdapter.mjs';
import { GpuBatchAdaptor } from '../../batcher/gpu/GpuBatchAdaptor.mjs';
import { AbstractRenderer } from '../shared/system/AbstractRenderer.mjs';
import { SharedSystems, SharedRenderPipes } from '../shared/system/SharedSystems.mjs';
import { RendererType } from '../types.mjs';
import { BindGroupSystem } from './BindGroupSystem.mjs';
import { GpuBufferSystem } from './buffer/GpuBufferSystem.mjs';
import { GpuColorMaskSystem } from './GpuColorMaskSystem.mjs';
import { GpuDeviceSystem } from './GpuDeviceSystem.mjs';
import { GpuEncoderSystem } from './GpuEncoderSystem.mjs';
import { GpuLimitsSystem } from './GpuLimitsSystem.mjs';
import { GpuStencilSystem } from './GpuStencilSystem.mjs';
import { GpuUboSystem } from './GpuUboSystem.mjs';
import { GpuUniformBatchPipe } from './GpuUniformBatchPipe.mjs';
import { PipelineSystem } from './pipeline/PipelineSystem.mjs';
import { GpuRenderTargetSystem } from './renderTarget/GpuRenderTargetSystem.mjs';
import { GpuShaderSystem } from './shader/GpuShaderSystem.mjs';
import { GpuStateSystem } from './state/GpuStateSystem.mjs';
import { GpuTextureSystem } from './texture/GpuTextureSystem.mjs';

"use strict";
const DefaultWebGPUSystems = [
  ...SharedSystems,
  GpuUboSystem,
  GpuEncoderSystem,
  GpuDeviceSystem,
  GpuLimitsSystem,
  GpuBufferSystem,
  GpuTextureSystem,
  GpuRenderTargetSystem,
  GpuShaderSystem,
  GpuStateSystem,
  PipelineSystem,
  GpuColorMaskSystem,
  GpuStencilSystem,
  BindGroupSystem
];
const DefaultWebGPUPipes = [...SharedRenderPipes, GpuUniformBatchPipe];
const DefaultWebGPUAdapters = [GpuBatchAdaptor, GpuMeshAdapter, GpuGraphicsAdaptor];
const systems = [];
const renderPipes = [];
const renderPipeAdaptors = [];
extensions.handleByNamedList(ExtensionType.WebGPUSystem, systems);
extensions.handleByNamedList(ExtensionType.WebGPUPipes, renderPipes);
extensions.handleByNamedList(ExtensionType.WebGPUPipesAdaptor, renderPipeAdaptors);
extensions.add(...DefaultWebGPUSystems, ...DefaultWebGPUPipes, ...DefaultWebGPUAdapters);
class WebGPURenderer extends AbstractRenderer {
  constructor() {
    const systemConfig = {
      name: "webgpu",
      type: RendererType.WEBGPU,
      systems,
      renderPipes,
      renderPipeAdaptors
    };
    super(systemConfig);
  }
}

export { WebGPURenderer };
//# sourceMappingURL=WebGPURenderer.mjs.map
