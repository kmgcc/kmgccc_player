'use strict';

"use strict";
const basisTranscoderUrls = {
  jsUrl: "https://cdn.jsdelivr.net/npm/pixi.js/transcoders/basis/basis_transcoder.js",
  wasmUrl: "https://cdn.jsdelivr.net/npm/pixi.js/transcoders/basis/basis_transcoder.wasm"
};
function setBasisTranscoderPath(config) {
  Object.assign(basisTranscoderUrls, config);
}

exports.basisTranscoderUrls = basisTranscoderUrls;
exports.setBasisTranscoderPath = setBasisTranscoderPath;
//# sourceMappingURL=setBasisTranscoderPath.js.map
