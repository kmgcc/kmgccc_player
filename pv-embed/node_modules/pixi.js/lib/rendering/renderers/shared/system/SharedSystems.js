'use strict';

var CustomRenderPipe = require('../../../../scene/container/CustomRenderPipe.js');
var RenderGroupPipe = require('../../../../scene/container/RenderGroupPipe.js');
var RenderGroupSystem = require('../../../../scene/container/RenderGroupSystem.js');
var SpritePipe = require('../../../../scene/sprite/SpritePipe.js');
var globalHooks = require('../../../../utils/global/globalHooks.js');
var BatcherPipe = require('../../../batcher/shared/BatcherPipe.js');
var AlphaMaskPipe = require('../../../mask/alpha/AlphaMaskPipe.js');
var ColorMaskPipe = require('../../../mask/color/ColorMaskPipe.js');
var StencilMaskPipe = require('../../../mask/stencil/StencilMaskPipe.js');
var BackgroundSystem = require('../background/BackgroundSystem.js');
var BlendModePipe = require('../blendModes/BlendModePipe.js');
var ExtractSystem = require('../extract/ExtractSystem.js');
var GenerateTextureSystem = require('../extract/GenerateTextureSystem.js');
var GCSystem = require('../GCSystem.js');
var GlobalUniformSystem = require('../renderTarget/GlobalUniformSystem.js');
var SchedulerSystem = require('../SchedulerSystem.js');
var HelloSystem = require('../startup/HelloSystem.js');
var RenderableGCSystem = require('../texture/RenderableGCSystem.js');
var TextureGCSystem = require('../texture/TextureGCSystem.js');
var ViewSystem = require('../view/ViewSystem.js');

"use strict";
const SharedSystems = [
  BackgroundSystem.BackgroundSystem,
  GlobalUniformSystem.GlobalUniformSystem,
  HelloSystem.HelloSystem,
  ViewSystem.ViewSystem,
  RenderGroupSystem.RenderGroupSystem,
  GCSystem.GCSystem,
  TextureGCSystem.TextureGCSystem,
  GenerateTextureSystem.GenerateTextureSystem,
  ExtractSystem.ExtractSystem,
  globalHooks.RendererInitHook,
  RenderableGCSystem.RenderableGCSystem,
  SchedulerSystem.SchedulerSystem
];
const SharedRenderPipes = [
  BlendModePipe.BlendModePipe,
  BatcherPipe.BatcherPipe,
  SpritePipe.SpritePipe,
  RenderGroupPipe.RenderGroupPipe,
  AlphaMaskPipe.AlphaMaskPipe,
  StencilMaskPipe.StencilMaskPipe,
  ColorMaskPipe.ColorMaskPipe,
  CustomRenderPipe.CustomRenderPipe
];

exports.SharedRenderPipes = SharedRenderPipes;
exports.SharedSystems = SharedSystems;
//# sourceMappingURL=SharedSystems.js.map
