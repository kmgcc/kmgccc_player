import { GlUboSystem } from '../rendering/renderers/gl/GlUboSystem.mjs';
import { GlShaderSystem } from '../rendering/renderers/gl/shader/GlShaderSystem.mjs';
import { GlUniformGroupSystem } from '../rendering/renderers/gl/shader/GlUniformGroupSystem.mjs';
import { GpuUboSystem } from '../rendering/renderers/gpu/GpuUboSystem.mjs';
import { UboSystem } from '../rendering/renderers/shared/shader/UboSystem.mjs';
import { AbstractRenderer } from '../rendering/renderers/shared/system/AbstractRenderer.mjs';
import { ParticleBuffer } from '../scene/particle-container/shared/ParticleBuffer.mjs';
import { generateParticleUpdatePolyfill } from './particle/generateParticleUpdatePolyfill.mjs';
import { generateShaderSyncPolyfill } from './shader/generateShaderSyncPolyfill.mjs';
import { generateUboSyncPolyfillSTD40, generateUboSyncPolyfillWGSL } from './ubo/generateUboSyncPolyfill.mjs';
import { generateUniformsSyncPolyfill } from './uniforms/generateUniformsSyncPolyfill.mjs';

"use strict";
function selfInstall() {
  Object.assign(AbstractRenderer.prototype, {
    // override unsafeEval check, as we don't need to use it
    _unsafeEvalCheck() {
    }
  });
  Object.assign(UboSystem.prototype, {
    // override unsafeEval check, as we don't need to use it
    _systemCheck() {
    }
  });
  Object.assign(GlUniformGroupSystem.prototype, {
    // use polyfill which avoids eval method
    _generateUniformsSync: generateUniformsSyncPolyfill
  });
  Object.assign(GlUboSystem.prototype, {
    // use polyfill which avoids eval method
    _generateUboSync: generateUboSyncPolyfillSTD40
  });
  Object.assign(GpuUboSystem.prototype, {
    // use polyfill which avoids eval method
    _generateUboSync: generateUboSyncPolyfillWGSL
  });
  Object.assign(GlShaderSystem.prototype, {
    // use polyfill which avoids eval method
    _generateShaderSync: generateShaderSyncPolyfill
  });
  Object.assign(ParticleBuffer.prototype, {
    // use polyfill which avoids eval method
    generateParticleUpdate: generateParticleUpdatePolyfill
  });
}
selfInstall();
//# sourceMappingURL=init.mjs.map
