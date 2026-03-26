"use strict";
function getUboData(program, gl) {
  if (!gl.ACTIVE_UNIFORM_BLOCKS) return {};
  const uniformBlocks = {};
  const totalUniformsBlocks = gl.getProgramParameter(program, gl.ACTIVE_UNIFORM_BLOCKS);
  for (let i = 0; i < totalUniformsBlocks; i++) {
    const name = gl.getActiveUniformBlockName(program, i);
    const uniformBlockIndex = gl.getUniformBlockIndex(program, name);
    const size = gl.getActiveUniformBlockParameter(program, i, gl.UNIFORM_BLOCK_DATA_SIZE);
    uniformBlocks[name] = {
      name,
      index: uniformBlockIndex,
      size
    };
  }
  return uniformBlocks;
}

export { getUboData };
//# sourceMappingURL=getUboData.mjs.map
