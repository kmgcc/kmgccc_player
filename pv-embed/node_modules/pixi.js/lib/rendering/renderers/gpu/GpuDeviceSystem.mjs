import { DOMAdapter } from '../../../environment/adapter.mjs';
import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
class GpuDeviceSystem {
  /**
   * @param {WebGPURenderer} renderer - The renderer this System works for.
   */
  constructor(renderer) {
    this._renderer = renderer;
  }
  async init(options) {
    if (this._initPromise) return this._initPromise;
    this._initPromise = (options.gpu ? Promise.resolve(options.gpu) : this._createDeviceAndAdaptor(options)).then((gpu) => {
      this.gpu = gpu;
      this._renderer.runners.contextChange.emit(this.gpu);
    });
    return this._initPromise;
  }
  /**
   * Handle the context change event
   * @param gpu
   */
  contextChange(gpu) {
    this._renderer.gpu = gpu;
  }
  /**
   * Helper class to create a WebGL Context
   * @param {object} options - An options object that gets passed in to the canvas element containing the
   *    context attributes
   * @see https://developer.mozilla.org/en/docs/Web/API/HTMLCanvasElement/getContext
   * @returns {WebGLRenderingContext} the WebGL context
   */
  async _createDeviceAndAdaptor(options) {
    const adapter = await DOMAdapter.get().getNavigator().gpu.requestAdapter({
      powerPreference: options.powerPreference,
      forceFallbackAdapter: options.forceFallbackAdapter
    });
    const requiredFeatures = [
      "texture-compression-bc",
      "texture-compression-astc",
      "texture-compression-etc2"
    ].filter((feature) => adapter.features.has(feature));
    const device = await adapter.requestDevice({
      requiredFeatures
    });
    return { adapter, device };
  }
  destroy() {
    this.gpu = null;
    this._renderer = null;
  }
}
/** @ignore */
GpuDeviceSystem.extension = {
  type: [
    ExtensionType.WebGPUSystem
  ],
  name: "device"
};
/** The default options for the GpuDeviceSystem. */
GpuDeviceSystem.defaultOptions = {
  /**
   * {@link WebGPUOptions.powerPreference}
   * @default default
   */
  powerPreference: void 0,
  /**
   * Force the use of the fallback adapter
   * @default false
   */
  forceFallbackAdapter: false
};

export { GpuDeviceSystem };
//# sourceMappingURL=GpuDeviceSystem.mjs.map
