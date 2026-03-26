import { GlProgram } from '../../../../rendering/renderers/gl/shader/GlProgram.mjs';
import { generateBlurFragSource } from './generateBlurFragSource.mjs';
import { generateBlurVertSource } from './generateBlurVertSource.mjs';

"use strict";
function generateBlurGlProgram(horizontal, kernelSize) {
  const vertex = generateBlurVertSource(kernelSize, horizontal);
  const fragment = generateBlurFragSource(kernelSize);
  return GlProgram.from({
    vertex,
    fragment,
    name: `blur-${horizontal ? "horizontal" : "vertical"}-pass-filter`
  });
}

export { generateBlurGlProgram };
//# sourceMappingURL=generateBlurGlProgram.mjs.map
