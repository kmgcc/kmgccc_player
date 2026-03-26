import WorkerInstance from '../../../_virtual/basis.worker.mjs';
import { basisTranscoderUrls } from '../utils/setBasisTranscoderPath.mjs';

"use strict";
let basisWorker;
const urlHash = {};
function getBasisWorker(supportedTextures) {
  if (!basisWorker) {
    basisWorker = new WorkerInstance().worker;
    basisWorker.onmessage = (messageEvent) => {
      const { success, url, textureOptions } = messageEvent.data;
      if (!success) {
        console.warn("Failed to load Basis texture", url);
      }
      urlHash[url](textureOptions);
    };
    basisWorker.postMessage({
      type: "init",
      jsUrl: basisTranscoderUrls.jsUrl,
      wasmUrl: basisTranscoderUrls.wasmUrl,
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

export { loadBasisOnWorker };
//# sourceMappingURL=loadBasisOnWorker.mjs.map
