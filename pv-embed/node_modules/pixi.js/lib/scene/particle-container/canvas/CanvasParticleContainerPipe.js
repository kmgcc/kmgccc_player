'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var ParticleContainerPipe = require('../shared/ParticleContainerPipe.js');
var CanvasParticleContainerAdaptor = require('./CanvasParticleContainerAdaptor.js');

"use strict";
class CanvasParticleContainerPipe extends ParticleContainerPipe.ParticleContainerPipe {
  constructor(renderer) {
    super(renderer, new CanvasParticleContainerAdaptor.CanvasParticleContainerAdaptor());
  }
}
/** @ignore */
CanvasParticleContainerPipe.extension = {
  type: [
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "particle"
};

exports.CanvasParticleContainerPipe = CanvasParticleContainerPipe;
//# sourceMappingURL=CanvasParticleContainerPipe.js.map
