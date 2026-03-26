'use strict';

"use strict";
function validateRenderables(renderGroup, renderPipes) {
  const { list } = renderGroup.childrenRenderablesToUpdate;
  let rebuildRequired = false;
  for (let i = 0; i < renderGroup.childrenRenderablesToUpdate.index; i++) {
    const container = list[i];
    const renderable = container;
    const pipe = renderPipes[renderable.renderPipeId];
    rebuildRequired = pipe.validateRenderable(container);
    if (rebuildRequired) {
      break;
    }
  }
  renderGroup.structureDidChange = rebuildRequired;
  return rebuildRequired;
}

exports.validateRenderables = validateRenderables;
//# sourceMappingURL=validateRenderables.js.map
