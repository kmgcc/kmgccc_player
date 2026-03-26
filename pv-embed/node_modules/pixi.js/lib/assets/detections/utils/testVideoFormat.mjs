"use strict";
const inWorker = "WorkerGlobalScope" in globalThis && globalThis instanceof globalThis.WorkerGlobalScope;
function testVideoFormat(mimeType) {
  if (inWorker) {
    return false;
  }
  const video = document.createElement("video");
  return video.canPlayType(mimeType) !== "";
}

export { testVideoFormat };
//# sourceMappingURL=testVideoFormat.mjs.map
