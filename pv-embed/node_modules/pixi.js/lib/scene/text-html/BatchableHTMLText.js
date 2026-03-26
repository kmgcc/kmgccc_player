'use strict';

var BatchableSprite = require('../sprite/BatchableSprite.js');

"use strict";
class BatchableHTMLText extends BatchableSprite.BatchableSprite {
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

exports.BatchableHTMLText = BatchableHTMLText;
//# sourceMappingURL=BatchableHTMLText.js.map
