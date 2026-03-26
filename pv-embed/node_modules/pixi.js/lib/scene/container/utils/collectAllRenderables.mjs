import { deprecation } from '../../../utils/logging/deprecation.mjs';

"use strict";
function collectAllRenderables(container, instructionSet, rendererOrPipes) {
  deprecation("8.7.0", "Please use container.collectRenderables instead.");
  const renderer = rendererOrPipes.renderPipes ? rendererOrPipes : rendererOrPipes.batch.renderer;
  return container.collectRenderables(instructionSet, renderer, null);
}

export { collectAllRenderables };
//# sourceMappingURL=collectAllRenderables.mjs.map
