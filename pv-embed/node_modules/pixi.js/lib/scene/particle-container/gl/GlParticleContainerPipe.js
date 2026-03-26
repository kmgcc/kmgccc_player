'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var GlParticleContainerAdaptor = require('./GlParticleContainerAdaptor.js');
var ParticleContainerPipe = require('../shared/ParticleContainerPipe.js');

"use strict";
class GlParticleContainerPipe extends ParticleContainerPipe.ParticleContainerPipe {
  constructor(renderer) {
    super(renderer, new GlParticleContainerAdaptor.GlParticleContainerAdaptor());
  }
}
/** @ignore */
GlParticleContainerPipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes
  ],
  name: "particle"
};

exports.GlParticleContainerPipe = GlParticleContainerPipe;
//# sourceMappingURL=GlParticleContainerPipe.js.map
