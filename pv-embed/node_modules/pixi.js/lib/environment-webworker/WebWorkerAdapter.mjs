import { DOMParser } from '@xmldom/xmldom';

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
    const parser = new DOMParser();
    return parser.parseFromString(xml, "text/xml");
  }
};

export { WebWorkerAdapter };
//# sourceMappingURL=WebWorkerAdapter.mjs.map
