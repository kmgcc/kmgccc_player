'use strict';

var getTestContext = require('../../../renderers/gl/shader/program/getTestContext.js');
var checkMaxIfStatementsInShader = require('./checkMaxIfStatementsInShader.js');

"use strict";
let maxTexturesPerBatchCache = null;
function getMaxTexturesPerBatch() {
  if (maxTexturesPerBatchCache) return maxTexturesPerBatchCache;
  const gl = getTestContext.getTestContext();
  maxTexturesPerBatchCache = gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS);
  maxTexturesPerBatchCache = checkMaxIfStatementsInShader.checkMaxIfStatementsInShader(
    maxTexturesPerBatchCache,
    gl
  );
  gl.getExtension("WEBGL_lose_context")?.loseContext();
  return maxTexturesPerBatchCache;
}

exports.getMaxTexturesPerBatch = getMaxTexturesPerBatch;
//# sourceMappingURL=maxRecommendedTextures.js.map
