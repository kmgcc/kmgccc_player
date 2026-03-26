import { extensions } from '../../extensions/Extensions.mjs';
import { CanvasGraphicsContextSystem } from './canvas/CanvasGraphicsContextSystem.mjs';
import { CanvasGraphicsPipe } from './canvas/CanvasGraphicsPipe.mjs';
import { GraphicsContextSystem } from './shared/GraphicsContextSystem.mjs';
import { GraphicsPipe } from './shared/GraphicsPipe.mjs';

"use strict";
extensions.add(CanvasGraphicsPipe);
extensions.add(GraphicsPipe);
extensions.add(CanvasGraphicsContextSystem);
extensions.add(GraphicsContextSystem);
//# sourceMappingURL=init.mjs.map
