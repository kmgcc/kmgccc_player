'use strict';

var GlProgram = require('../../../../rendering/renderers/gl/shader/GlProgram.js');
var generateBlurFragSource = require('./generateBlurFragSource.js');
var generateBlurVertSource = require('./generateBlurVertSource.js');

"use strict";
function generateBlurGlProgram(horizontal, kernelSize) {
  const vertex = generateBlurVertSource.generateBlurVertSource(kernelSize, horizontal);
  const fragment = generateBlurFragSource.generateBlurFragSource(kernelSize);
  return GlProgram.GlProgram.from({
    vertex,
    fragment,
    name: `blur-${horizontal ? "horizontal" : "vertical"}-pass-filter`
  });
}

exports.generateBlurGlProgram = generateBlurGlProgram;
//# sourceMappingURL=generateBlurGlProgram.js.map
