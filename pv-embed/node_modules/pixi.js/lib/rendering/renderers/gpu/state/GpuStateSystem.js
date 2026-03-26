'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var State = require('../../shared/state/State.js');
var GpuBlendModesToPixi = require('./GpuBlendModesToPixi.js');

"use strict";
class GpuStateSystem {
  constructor() {
    this.defaultState = new State.State();
    this.defaultState.blend = true;
  }
  contextChange(gpu) {
    this.gpu = gpu;
  }
  /**
   * Gets the blend mode data for the current state
   * @param state - The state to get the blend mode from
   * @param count - The number of color targets to create
   */
  getColorTargets(state, count) {
    const blend = GpuBlendModesToPixi.GpuBlendModesToPixi[state.blendMode] || GpuBlendModesToPixi.GpuBlendModesToPixi.normal;
    const targets = [];
    const target = {
      format: "bgra8unorm",
      writeMask: 0,
      blend
    };
    for (let i = 0; i < count; i++) {
      targets[i] = target;
    }
    return targets;
  }
  destroy() {
    this.gpu = null;
  }
}
/** @ignore */
GpuStateSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "state"
};

exports.GpuStateSystem = GpuStateSystem;
//# sourceMappingURL=GpuStateSystem.js.map
