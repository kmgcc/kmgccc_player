"use strict";
const basisTranscoderUrls = {
  jsUrl: "https://cdn.jsdelivr.net/npm/pixi.js/transcoders/basis/basis_transcoder.js",
  wasmUrl: "https://cdn.jsdelivr.net/npm/pixi.js/transcoders/basis/basis_transcoder.wasm"
};
function setBasisTranscoderPath(config) {
  Object.assign(basisTranscoderUrls, config);
}

export { basisTranscoderUrls, setBasisTranscoderPath };
//# sourceMappingURL=setBasisTranscoderPath.mjs.map
