import { extensions } from '../../extensions/Extensions.mjs';
import { CanvasTextPipe } from './canvas/CanvasTextPipe.mjs';
import { CanvasRendererTextSystem } from './canvas/CanvasTextSystem.mjs';
import { CanvasTextSystem } from './shared/GpuTextSystem.mjs';

"use strict";
extensions.add(CanvasRendererTextSystem);
extensions.add(CanvasTextSystem);
extensions.add(CanvasTextPipe);
//# sourceMappingURL=init.mjs.map
