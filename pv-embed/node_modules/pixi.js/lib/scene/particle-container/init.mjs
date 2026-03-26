import { extensions } from '../../extensions/Extensions.mjs';
import { CanvasParticleContainerPipe } from './canvas/CanvasParticleContainerPipe.mjs';
import { GlParticleContainerPipe } from './gl/GlParticleContainerPipe.mjs';
import { GpuParticleContainerPipe } from './gpu/GpuParticleContainerPipe.mjs';

"use strict";
extensions.add(GlParticleContainerPipe);
extensions.add(GpuParticleContainerPipe);
extensions.add(CanvasParticleContainerPipe);
//# sourceMappingURL=init.mjs.map
