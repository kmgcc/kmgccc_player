"use strict";
const collectRenderablesMixin = {
  collectRenderables(instructionSet, renderer, currentLayer) {
    if (this.parentRenderLayer && this.parentRenderLayer !== currentLayer || this.globalDisplayStatus < 7 || !this.includeInBuild) return;
    if (this.sortableChildren) {
      this.sortChildren();
    }
    if (this.isSimple) {
      this.collectRenderablesSimple(instructionSet, renderer, currentLayer);
    } else if (this.renderGroup) {
      renderer.renderPipes.renderGroup.addRenderGroup(this.renderGroup, instructionSet);
    } else {
      this.collectRenderablesWithEffects(instructionSet, renderer, currentLayer);
    }
  },
  collectRenderablesSimple(instructionSet, renderer, currentLayer) {
    const children = this.children;
    const length = children.length;
    for (let i = 0; i < length; i++) {
      children[i].collectRenderables(instructionSet, renderer, currentLayer);
    }
  },
  collectRenderablesWithEffects(instructionSet, renderer, currentLayer) {
    const { renderPipes } = renderer;
    for (let i = 0; i < this.effects.length; i++) {
      const effect = this.effects[i];
      const pipe = renderPipes[effect.pipe];
      pipe.push(effect, this, instructionSet);
    }
    this.collectRenderablesSimple(instructionSet, renderer, currentLayer);
    for (let i = this.effects.length - 1; i >= 0; i--) {
      const effect = this.effects[i];
      const pipe = renderPipes[effect.pipe];
      pipe.pop(effect, this, instructionSet);
    }
  }
};

export { collectRenderablesMixin };
//# sourceMappingURL=collectRenderablesMixin.mjs.map
