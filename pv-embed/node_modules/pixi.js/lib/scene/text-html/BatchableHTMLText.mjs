import { BatchableSprite } from '../sprite/BatchableSprite.mjs';

"use strict";
class BatchableHTMLText extends BatchableSprite {
  constructor() {
    super(...arguments);
    this.generatingTexture = false;
    this.currentKey = "--";
  }
  /** Destroys the BatchableHTMLText instance. Returns the texture promise to the renderer and cleans up references. */
  destroy() {
    this.texturePromise = null;
    this.generatingTexture = false;
    this.currentKey = "--";
    super.destroy();
  }
}

export { BatchableHTMLText };
//# sourceMappingURL=BatchableHTMLText.mjs.map
