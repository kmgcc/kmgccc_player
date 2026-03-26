'use strict';

var xmldom = require('@xmldom/xmldom');

"use strict";
const WebWorkerAdapter = {
  createCanvas: (width, height) => new OffscreenCanvas(width ?? 0, height ?? 0),
  createImage: () => new Image(),
  getCanvasRenderingContext2D: () => OffscreenCanvasRenderingContext2D,
  getWebGLRenderingContext: () => WebGLRenderingContext,
  getNavigator: () => navigator,
  getBaseUrl: () => globalThis.location.href,
  getFontFaceSet: () => globalThis.fonts,
  fetch: (url, options) => fetch(url, options),
  parseXML: (xml) => {
    const parser = new xmldom.DOMParser();
    return parser.parseFromString(xml, "text/xml");
  }
};

exports.WebWorkerAdapter = WebWorkerAdapter;
//# sourceMappingURL=WebWorkerAdapter.js.map
