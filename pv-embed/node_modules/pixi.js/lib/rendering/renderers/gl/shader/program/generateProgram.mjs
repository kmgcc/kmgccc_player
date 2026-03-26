import { warn } from '../../../../../utils/logging/warn.mjs';
import { GlProgramData } from '../GlProgramData.mjs';
import { compileShader } from './compileShader.mjs';
import { defaultValue } from './defaultValue.mjs';
import { extractAttributesFromGlProgram } from './extractAttributesFromGlProgram.mjs';
import { getUboData } from './getUboData.mjs';
import { getUniformData } from './getUniformData.mjs';
import { logProgramError } from './logProgramError.mjs';

"use strict";
function generateProgram(gl, program) {
  const glVertShader = compileShader(gl, gl.VERTEX_SHADER, program.vertex);
  const glFragShader = compileShader(gl, gl.FRAGMENT_SHADER, program.fragment);
  const webGLProgram = gl.createProgram();
  gl.attachShader(webGLProgram, glVertShader);
  gl.attachShader(webGLProgram, glFragShader);
  const transformFeedbackVaryings = program.transformFeedbackVaryings;
  if (transformFeedbackVaryings) {
    if (typeof gl.transformFeedbackVaryings !== "function") {
      warn(`TransformFeedback is not supported but TransformFeedbackVaryings are given.`);
    } else {
      gl.transformFeedbackVaryings(
        webGLProgram,
        transformFeedbackVaryings.names,
        transformFeedbackVaryings.bufferMode === "separate" ? gl.SEPARATE_ATTRIBS : gl.INTERLEAVED_ATTRIBS
      );
    }
  }
  gl.linkProgram(webGLProgram);
  if (!gl.getProgramParameter(webGLProgram, gl.LINK_STATUS)) {
    logProgramError(gl, webGLProgram, glVertShader, glFragShader);
  }
  program._attributeData = extractAttributesFromGlProgram(
    webGLProgram,
    gl,
    !/^[ \t]*#[ \t]*version[ \t]+300[ \t]+es[ \t]*$/m.test(program.vertex)
  );
  program._uniformData = getUniformData(webGLProgram, gl);
  program._uniformBlockData = getUboData(webGLProgram, gl);
  gl.deleteShader(glVertShader);
  gl.deleteShader(glFragShader);
  const uniformData = {};
  for (const i in program._uniformData) {
    const data = program._uniformData[i];
    uniformData[i] = {
      location: gl.getUniformLocation(webGLProgram, i),
      value: defaultValue(data.type, data.size)
    };
  }
  const glProgram = new GlProgramData(webGLProgram, uniformData);
  return glProgram;
}

export { generateProgram };
//# sourceMappingURL=generateProgram.mjs.map
