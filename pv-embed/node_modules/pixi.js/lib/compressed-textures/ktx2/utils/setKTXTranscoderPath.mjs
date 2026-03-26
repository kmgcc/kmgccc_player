"use strict";
const ktxTranscoderUrls = {
  jsUrl: "https://cdn.jsdelivr.net/npm/pixi.js/transcoders/ktx/libktx.js",
  wasmUrl: "https://cdn.jsdelivr.net/npm/pixi.js/transcoders/ktx/libktx.wasm"
};
function setKTXTranscoderPath(config) {
  Object.assign(ktxTranscoderUrls, config);
}

export { ktxTranscoderUrls, setKTXTranscoderPath };
//# sourceMappingURL=setKTXTranscoderPath.mjs.map
