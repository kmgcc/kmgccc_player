import { getTestContext } from '../../../renderers/gl/shader/program/getTestContext.mjs';
import { checkMaxIfStatementsInShader } from './checkMaxIfStatementsInShader.mjs';

"use strict";
let maxTexturesPerBatchCache = null;
function getMaxTexturesPerBatch() {
  if (maxTexturesPerBatchCache) return maxTexturesPerBatchCache;
  const gl = getTestContext();
  maxTexturesPerBatchCache = gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS);
  maxTexturesPerBatchCache = checkMaxIfStatementsInShader(
    maxTexturesPerBatchCache,
    gl
  );
  gl.getExtension("WEBGL_lose_context")?.loseContext();
  return maxTexturesPerBatchCache;
}

export { getMaxTexturesPerBatch };
//# sourceMappingURL=maxRecommendedTextures.mjs.map
