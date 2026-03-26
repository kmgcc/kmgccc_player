'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var GpuGraphicsAdaptor = require('../../../scene/graphics/gpu/GpuGraphicsAdaptor.js');
var GpuMeshAdapter = require('../../../scene/mesh/gpu/GpuMeshAdapter.js');
var GpuBatchAdaptor = require('../../batcher/gpu/GpuBatchAdaptor.js');
var AbstractRenderer = require('../shared/system/AbstractRenderer.js');
var SharedSystems = require('../shared/system/SharedSystems.js');
var types = require('../types.js');
var BindGroupSystem = require('./BindGroupSystem.js');
var GpuBufferSystem = require('./buffer/GpuBufferSystem.js');
var GpuColorMaskSystem = require('./GpuColorMaskSystem.js');
var GpuDeviceSystem = require('./GpuDeviceSystem.js');
var GpuEncoderSystem = require('./GpuEncoderSystem.js');
var GpuLimitsSystem = require('./GpuLimitsSystem.js');
var GpuStencilSystem = require('./GpuStencilSystem.js');
var GpuUboSystem = require('./GpuUboSystem.js');
var GpuUniformBatchPipe = require('./GpuUniformBatchPipe.js');
var PipelineSystem = require('./pipeline/PipelineSystem.js');
var GpuRenderTargetSystem = require('./renderTarget/GpuRenderTargetSystem.js');
var GpuShaderSystem = require('./shader/GpuShaderSystem.js');
var GpuStateSystem = require('./state/GpuStateSystem.js');
var GpuTextureSystem = require('./texture/GpuTextureSystem.js');

"use strict";
const DefaultWebGPUSystems = [
  ...SharedSystems.SharedSystems,
  GpuUboSystem.GpuUboSystem,
  GpuEncoderSystem.GpuEncoderSystem,
  GpuDeviceSystem.GpuDeviceSystem,
  GpuLimitsSystem.GpuLimitsSystem,
  GpuBufferSystem.GpuBufferSystem,
  GpuTextureSystem.GpuTextureSystem,
  GpuRenderTargetSystem.GpuRenderTargetSystem,
  GpuShaderSystem.GpuShaderSystem,
  GpuStateSystem.GpuStateSystem,
  PipelineSystem.PipelineSystem,
  GpuColorMaskSystem.GpuColorMaskSystem,
  GpuStencilSystem.GpuStencilSystem,
  BindGroupSystem.BindGroupSystem
];
const DefaultWebGPUPipes = [...SharedSystems.SharedRenderPipes, GpuUniformBatchPipe.GpuUniformBatchPipe];
const DefaultWebGPUAdapters = [GpuBatchAdaptor.GpuBatchAdaptor, GpuMeshAdapter.GpuMeshAdapter, GpuGraphicsAdaptor.GpuGraphicsAdaptor];
const systems = [];
const renderPipes = [];
const renderPipeAdaptors = [];
Extensions.extensions.handleByNamedList(Extensions.ExtensionType.WebGPUSystem, systems);
Extensions.extensions.handleByNamedList(Extensions.ExtensionType.WebGPUPipes, renderPipes);
Extensions.extensions.handleByNamedList(Extensions.ExtensionType.WebGPUPipesAdaptor, renderPipeAdaptors);
Extensions.extensions.add(...DefaultWebGPUSystems, ...DefaultWebGPUPipes, ...DefaultWebGPUAdapters);
class WebGPURenderer extends AbstractRenderer.AbstractRenderer {
  constructor() {
    const systemConfig = {
      name: "webgpu",
      type: types.RendererType.WEBGPU,
      systems,
      renderPipes,
      renderPipeAdaptors
    };
    super(systemConfig);
  }
}

exports.WebGPURenderer = WebGPURenderer;
//# sourceMappingURL=WebGPURenderer.js.map
