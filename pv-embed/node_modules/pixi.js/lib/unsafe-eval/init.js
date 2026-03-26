'use strict';

var GlUboSystem = require('../rendering/renderers/gl/GlUboSystem.js');
var GlShaderSystem = require('../rendering/renderers/gl/shader/GlShaderSystem.js');
var GlUniformGroupSystem = require('../rendering/renderers/gl/shader/GlUniformGroupSystem.js');
var GpuUboSystem = require('../rendering/renderers/gpu/GpuUboSystem.js');
var UboSystem = require('../rendering/renderers/shared/shader/UboSystem.js');
var AbstractRenderer = require('../rendering/renderers/shared/system/AbstractRenderer.js');
var ParticleBuffer = require('../scene/particle-container/shared/ParticleBuffer.js');
var generateParticleUpdatePolyfill = require('./particle/generateParticleUpdatePolyfill.js');
var generateShaderSyncPolyfill = require('./shader/generateShaderSyncPolyfill.js');
var generateUboSyncPolyfill = require('./ubo/generateUboSyncPolyfill.js');
var generateUniformsSyncPolyfill = require('./uniforms/generateUniformsSyncPolyfill.js');

"use strict";
function selfInstall() {
  Object.assign(AbstractRenderer.AbstractRenderer.prototype, {
    // override unsafeEval check, as we don't need to use it
    _unsafeEvalCheck() {
    }
  });
  Object.assign(UboSystem.UboSystem.prototype, {
    // override unsafeEval check, as we don't need to use it
    _systemCheck() {
    }
  });
  Object.assign(GlUniformGroupSystem.GlUniformGroupSystem.prototype, {
    // use polyfill which avoids eval method
    _generateUniformsSync: generateUniformsSyncPolyfill.generateUniformsSyncPolyfill
  });
  Object.assign(GlUboSystem.GlUboSystem.prototype, {
    // use polyfill which avoids eval method
    _generateUboSync: generateUboSyncPolyfill.generateUboSyncPolyfillSTD40
  });
  Object.assign(GpuUboSystem.GpuUboSystem.prototype, {
    // use polyfill which avoids eval method
    _generateUboSync: generateUboSyncPolyfill.generateUboSyncPolyfillWGSL
  });
  Object.assign(GlShaderSystem.GlShaderSystem.prototype, {
    // use polyfill which avoids eval method
    _generateShaderSync: generateShaderSyncPolyfill.generateShaderSyncPolyfill
  });
  Object.assign(ParticleBuffer.ParticleBuffer.prototype, {
    // use polyfill which avoids eval method
    generateParticleUpdate: generateParticleUpdatePolyfill.generateParticleUpdatePolyfill
  });
}
selfInstall();
//# sourceMappingURL=init.js.map
