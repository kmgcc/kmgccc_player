import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { ParticleContainerPipe } from '../shared/ParticleContainerPipe.mjs';
import { CanvasParticleContainerAdaptor } from './CanvasParticleContainerAdaptor.mjs';

"use strict";
class CanvasParticleContainerPipe extends ParticleContainerPipe {
  constructor(renderer) {
    super(renderer, new CanvasParticleContainerAdaptor());
  }
}
/** @ignore */
CanvasParticleContainerPipe.extension = {
  type: [
    ExtensionType.CanvasPipes
  ],
  name: "particle"
};

export { CanvasParticleContainerPipe };
//# sourceMappingURL=CanvasParticleContainerPipe.mjs.map
