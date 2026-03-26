import { unsafeEvalSupported } from '../../../../utils/browser/unsafeEvalSupported.mjs';
import { Buffer } from '../buffer/Buffer.mjs';
import { BufferUsage } from '../buffer/const.mjs';

"use strict";
class UboSystem {
  constructor(adaptor) {
    /** Cache of uniform buffer layouts and sync functions, so we don't have to re-create them */
    this._syncFunctionHash = /* @__PURE__ */ Object.create(null);
    this._adaptor = adaptor;
    this._systemCheck();
  }
  /**
   * Overridable function by `pixi.js/unsafe-eval` to silence
   * throwing an error if platform doesn't support unsafe-evals.
   * @private
   */
  _systemCheck() {
    if (!unsafeEvalSupported()) {
      throw new Error("Current environment does not allow unsafe-eval, please use pixi.js/unsafe-eval module to enable support.");
    }
  }
  ensureUniformGroup(uniformGroup) {
    const uniformData = this.getUniformGroupData(uniformGroup);
    uniformGroup.buffer || (uniformGroup.buffer = new Buffer({
      data: new Float32Array(uniformData.layout.size / 4),
      usage: BufferUsage.UNIFORM | BufferUsage.COPY_DST
    }));
  }
  getUniformGroupData(uniformGroup) {
    return this._syncFunctionHash[uniformGroup._signature] || this._initUniformGroup(uniformGroup);
  }
  _initUniformGroup(uniformGroup) {
    const uniformGroupSignature = uniformGroup._signature;
    let uniformData = this._syncFunctionHash[uniformGroupSignature];
    if (!uniformData) {
      const elements = Object.keys(uniformGroup.uniformStructures).map((i) => uniformGroup.uniformStructures[i]);
      const layout = this._adaptor.createUboElements(elements);
      const syncFunction = this._generateUboSync(layout.uboElements);
      uniformData = this._syncFunctionHash[uniformGroupSignature] = {
        layout,
        syncFunction
      };
    }
    return this._syncFunctionHash[uniformGroupSignature];
  }
  _generateUboSync(uboElements) {
    return this._adaptor.generateUboSync(uboElements);
  }
  syncUniformGroup(uniformGroup, data, offset) {
    const uniformGroupData = this.getUniformGroupData(uniformGroup);
    uniformGroup.buffer || (uniformGroup.buffer = new Buffer({
      data: new Float32Array(uniformGroupData.layout.size / 4),
      usage: BufferUsage.UNIFORM | BufferUsage.COPY_DST
    }));
    let dataInt32 = null;
    if (!data) {
      data = uniformGroup.buffer.data;
      dataInt32 = uniformGroup.buffer.dataInt32;
    }
    offset || (offset = 0);
    uniformGroupData.syncFunction(uniformGroup.uniforms, data, dataInt32, offset);
    return true;
  }
  updateUniformGroup(uniformGroup) {
    if (uniformGroup.isStatic && !uniformGroup._dirtyId) return false;
    uniformGroup._dirtyId = 0;
    const synced = this.syncUniformGroup(uniformGroup);
    uniformGroup.buffer.update();
    return synced;
  }
  destroy() {
    this._syncFunctionHash = null;
  }
}

export { UboSystem };
//# sourceMappingURL=UboSystem.mjs.map
