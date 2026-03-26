'use strict';

var deprecation = require('../../../utils/logging/deprecation.js');

"use strict";
function collectAllRenderables(container, instructionSet, rendererOrPipes) {
  deprecation.deprecation("8.7.0", "Please use container.collectRenderables instead.");
  const renderer = rendererOrPipes.renderPipes ? rendererOrPipes : rendererOrPipes.batch.renderer;
  return container.collectRenderables(instructionSet, renderer, null);
}

exports.collectAllRenderables = collectAllRenderables;
//# sourceMappingURL=collectAllRenderables.js.map
