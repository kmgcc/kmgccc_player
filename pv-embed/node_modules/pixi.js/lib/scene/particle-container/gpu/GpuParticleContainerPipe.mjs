import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { GpuParticleContainerAdaptor } from './GpuParticleContainerAdaptor.mjs';
import { ParticleContainerPipe } from '../shared/ParticleContainerPipe.mjs';

"use strict";
class GpuParticleContainerPipe extends ParticleContainerPipe {
  constructor(renderer) {
    super(renderer, new GpuParticleContainerAdaptor());
  }
}
/** @ignore */
GpuParticleContainerPipe.extension = {
  type: [
    ExtensionType.WebGPUPipes
  ],
  name: "particle"
};

export { GpuParticleContainerPipe };
//# sourceMappingURL=GpuParticleContainerPipe.mjs.map
