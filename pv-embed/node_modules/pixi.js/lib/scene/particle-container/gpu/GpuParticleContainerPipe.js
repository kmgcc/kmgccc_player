'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var GpuParticleContainerAdaptor = require('./GpuParticleContainerAdaptor.js');
var ParticleContainerPipe = require('../shared/ParticleContainerPipe.js');

"use strict";
class GpuParticleContainerPipe extends ParticleContainerPipe.ParticleContainerPipe {
  constructor(renderer) {
    super(renderer, new GpuParticleContainerAdaptor.GpuParticleContainerAdaptor());
  }
}
/** @ignore */
GpuParticleContainerPipe.extension = {
  type: [
    Extensions.ExtensionType.WebGPUPipes
  ],
  name: "particle"
};

exports.GpuParticleContainerPipe = GpuParticleContainerPipe;
//# sourceMappingURL=GpuParticleContainerPipe.js.map
