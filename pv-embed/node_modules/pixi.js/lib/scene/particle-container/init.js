'use strict';

var Extensions = require('../../extensions/Extensions.js');
var CanvasParticleContainerPipe = require('./canvas/CanvasParticleContainerPipe.js');
var GlParticleContainerPipe = require('./gl/GlParticleContainerPipe.js');
var GpuParticleContainerPipe = require('./gpu/GpuParticleContainerPipe.js');

"use strict";
Extensions.extensions.add(GlParticleContainerPipe.GlParticleContainerPipe);
Extensions.extensions.add(GpuParticleContainerPipe.GpuParticleContainerPipe);
Extensions.extensions.add(CanvasParticleContainerPipe.CanvasParticleContainerPipe);
//# sourceMappingURL=init.js.map
