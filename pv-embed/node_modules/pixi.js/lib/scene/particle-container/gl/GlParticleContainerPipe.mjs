import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { GlParticleContainerAdaptor } from './GlParticleContainerAdaptor.mjs';
import { ParticleContainerPipe } from '../shared/ParticleContainerPipe.mjs';

"use strict";
class GlParticleContainerPipe extends ParticleContainerPipe {
  constructor(renderer) {
    super(renderer, new GlParticleContainerAdaptor());
  }
}
/** @ignore */
GlParticleContainerPipe.extension = {
  type: [
    ExtensionType.WebGLPipes
  ],
  name: "particle"
};

export { GlParticleContainerPipe };
//# sourceMappingURL=GlParticleContainerPipe.mjs.map
