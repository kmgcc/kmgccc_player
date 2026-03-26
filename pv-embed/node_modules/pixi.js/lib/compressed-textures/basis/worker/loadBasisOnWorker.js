'use strict';

var basis_worker = require('../../../_virtual/basis.worker.js');
var setBasisTranscoderPath = require('../utils/setBasisTranscoderPath.js');

"use strict";
let basisWorker;
const urlHash = {};
function getBasisWorker(supportedTextures) {
  if (!basisWorker) {
    basisWorker = new basis_worker.default().worker;
    basisWorker.onmessage = (messageEvent) => {
      const { success, url, textureOptions } = messageEvent.data;
      if (!success) {
        console.warn("Failed to load Basis texture", url);
      }
      urlHash[url](textureOptions);
    };
    basisWorker.postMessage({
      type: "init",
      jsUrl: setBasisTranscoderPath.basisTranscoderUrls.jsUrl,
      wasmUrl: setBasisTranscoderPath.basisTranscoderUrls.wasmUrl,
      supportedTextures
    });
  }
  return basisWorker;
}
function loadBasisOnWorker(url, supportedTextures) {
  const ktxWorker = getBasisWorker(supportedTextures);
  return new Promise((resolve) => {
    urlHash[url] = resolve;
    ktxWorker.postMessage({ type: "load", url });
  });
}

exports.loadBasisOnWorker = loadBasisOnWorker;
//# sourceMappingURL=loadBasisOnWorker.js.map
