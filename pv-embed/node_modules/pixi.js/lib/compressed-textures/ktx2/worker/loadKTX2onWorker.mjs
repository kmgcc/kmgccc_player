import WorkerInstance from '../../../_virtual/ktx.worker.mjs';
import { ktxTranscoderUrls } from '../utils/setKTXTranscoderPath.mjs';

"use strict";
let ktxWorker;
const urlHash = {};
const errorHash = {};
function getKTX2Worker(supportedTextures) {
  if (!ktxWorker) {
    ktxWorker = new WorkerInstance().worker;
    ktxWorker.onmessage = (messageEvent) => {
      const { err, success, url, textureOptions } = messageEvent.data;
      if (err) {
        errorHash[url](err);
        return;
      }
      if (!success) {
        console.warn("Failed to load KTX texture", url);
      }
      urlHash[url](textureOptions);
    };
    ktxWorker.postMessage({
      type: "init",
      jsUrl: ktxTranscoderUrls.jsUrl,
      wasmUrl: ktxTranscoderUrls.wasmUrl,
      supportedTextures
    });
  }
  return ktxWorker;
}
function loadKTX2onWorker(url, supportedTextures) {
  const ktxWorker2 = getKTX2Worker(supportedTextures);
  return new Promise((resolve, reject) => {
    urlHash[url] = resolve;
    errorHash[url] = reject;
    ktxWorker2.postMessage({ type: "load", url });
  });
}

export { loadKTX2onWorker };
//# sourceMappingURL=loadKTX2onWorker.mjs.map
