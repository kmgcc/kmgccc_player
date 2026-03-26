'use strict';

var isWebGLSupported = require('../../utils/browser/isWebGLSupported.js');
var isWebGPUSupported = require('../../utils/browser/isWebGPUSupported.js');
var AbstractRenderer = require('./shared/system/AbstractRenderer.js');

"use strict";
const renderPriority = ["webgl", "webgpu", "canvas"];
async function autoDetectRenderer(options) {
  let preferredOrder = [];
  if (options.preference) {
    preferredOrder.push(options.preference);
    renderPriority.forEach((item) => {
      if (item !== options.preference) {
        preferredOrder.push(item);
      }
    });
  } else {
    preferredOrder = renderPriority.slice();
  }
  let RendererClass;
  let finalOptions = {};
  for (let i = 0; i < preferredOrder.length; i++) {
    const rendererType = preferredOrder[i];
    if (rendererType === "webgpu" && await isWebGPUSupported.isWebGPUSupported()) {
      const { WebGPURenderer } = await Promise.resolve().then(function () { return require('./gpu/WebGPURenderer.js'); });
      RendererClass = WebGPURenderer;
      finalOptions = { ...options, ...options.webgpu };
      break;
    } else if (rendererType === "webgl" && isWebGLSupported.isWebGLSupported(
      options.failIfMajorPerformanceCaveat ?? AbstractRenderer.AbstractRenderer.defaultOptions.failIfMajorPerformanceCaveat
    )) {
      const { WebGLRenderer } = await Promise.resolve().then(function () { return require('./gl/WebGLRenderer.js'); });
      RendererClass = WebGLRenderer;
      finalOptions = { ...options, ...options.webgl };
      break;
    } else if (rendererType === "canvas") {
      const { CanvasRenderer } = await Promise.resolve().then(function () { return require('./canvas/CanvasRenderer.js'); });
      RendererClass = CanvasRenderer;
      finalOptions = { ...options, ...options.canvasOptions };
      break;
    }
  }
  delete finalOptions.webgpu;
  delete finalOptions.webgl;
  delete finalOptions.canvasOptions;
  if (!RendererClass) {
    throw new Error("No available renderer for the current environment");
  }
  const renderer = new RendererClass();
  await renderer.init(finalOptions);
  return renderer;
}

exports.autoDetectRenderer = autoDetectRenderer;
//# sourceMappingURL=autoDetectRenderer.js.map
