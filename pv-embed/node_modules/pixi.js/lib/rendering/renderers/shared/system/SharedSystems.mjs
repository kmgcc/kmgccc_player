import { CustomRenderPipe } from '../../../../scene/container/CustomRenderPipe.mjs';
import { RenderGroupPipe } from '../../../../scene/container/RenderGroupPipe.mjs';
import { RenderGroupSystem } from '../../../../scene/container/RenderGroupSystem.mjs';
import { SpritePipe } from '../../../../scene/sprite/SpritePipe.mjs';
import { RendererInitHook } from '../../../../utils/global/globalHooks.mjs';
import { BatcherPipe } from '../../../batcher/shared/BatcherPipe.mjs';
import { AlphaMaskPipe } from '../../../mask/alpha/AlphaMaskPipe.mjs';
import { ColorMaskPipe } from '../../../mask/color/ColorMaskPipe.mjs';
import { StencilMaskPipe } from '../../../mask/stencil/StencilMaskPipe.mjs';
import { BackgroundSystem } from '../background/BackgroundSystem.mjs';
import { BlendModePipe } from '../blendModes/BlendModePipe.mjs';
import { ExtractSystem } from '../extract/ExtractSystem.mjs';
import { GenerateTextureSystem } from '../extract/GenerateTextureSystem.mjs';
import { GCSystem } from '../GCSystem.mjs';
import { GlobalUniformSystem } from '../renderTarget/GlobalUniformSystem.mjs';
import { SchedulerSystem } from '../SchedulerSystem.mjs';
import { HelloSystem } from '../startup/HelloSystem.mjs';
import { RenderableGCSystem } from '../texture/RenderableGCSystem.mjs';
import { TextureGCSystem } from '../texture/TextureGCSystem.mjs';
import { ViewSystem } from '../view/ViewSystem.mjs';

"use strict";
const SharedSystems = [
  BackgroundSystem,
  GlobalUniformSystem,
  HelloSystem,
  ViewSystem,
  RenderGroupSystem,
  GCSystem,
  TextureGCSystem,
  GenerateTextureSystem,
  ExtractSystem,
  RendererInitHook,
  RenderableGCSystem,
  SchedulerSystem
];
const SharedRenderPipes = [
  BlendModePipe,
  BatcherPipe,
  SpritePipe,
  RenderGroupPipe,
  AlphaMaskPipe,
  StencilMaskPipe,
  ColorMaskPipe,
  CustomRenderPipe
];

export { SharedRenderPipes, SharedSystems };
//# sourceMappingURL=SharedSystems.mjs.map
