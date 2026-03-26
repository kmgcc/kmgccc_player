'use strict';

var Matrix = require('../../../../maths/matrix/Matrix.js');
var uid = require('../../../../utils/data/uid.js');

"use strict";
const repetitionMap = {
  repeat: {
    addressModeU: "repeat",
    addressModeV: "repeat"
  },
  "repeat-x": {
    addressModeU: "repeat",
    addressModeV: "clamp-to-edge"
  },
  "repeat-y": {
    addressModeU: "clamp-to-edge",
    addressModeV: "repeat"
  },
  "no-repeat": {
    addressModeU: "clamp-to-edge",
    addressModeV: "clamp-to-edge"
  }
};
class FillPattern {
  constructor(texture, repetition) {
    /**
     * unique id for this fill pattern
     * @internal
     */
    this.uid = uid.uid("fillPattern");
    /**
     * Internal tick counter to track changes in the pattern.
     * This is used to invalidate the pattern when the texture or transform changes.
     * @internal
     */
    this._tick = 0;
    /** The transform matrix applied to the pattern */
    this.transform = new Matrix.Matrix();
    this.texture = texture;
    this.transform.scale(
      1 / texture.frame.width,
      1 / texture.frame.height
    );
    if (repetition) {
      texture.source.style.addressModeU = repetitionMap[repetition].addressModeU;
      texture.source.style.addressModeV = repetitionMap[repetition].addressModeV;
    }
  }
  /**
   * Sets the transform for the pattern
   * @param transform - The transform matrix to apply to the pattern.
   * If not provided, the pattern will use the default transform.
   */
  setTransform(transform) {
    const texture = this.texture;
    this.transform.copyFrom(transform);
    this.transform.invert();
    this.transform.scale(
      1 / texture.frame.width,
      1 / texture.frame.height
    );
    this._tick++;
  }
  /** Internal texture used to render the gradient */
  get texture() {
    return this._texture;
  }
  set texture(value) {
    if (this._texture === value) return;
    this._texture = value;
    this._tick++;
  }
  /**
   * Returns a unique key for this instance.
   * This key is used for caching.
   * @returns {string} Unique key for the instance
   */
  get styleKey() {
    return `fill-pattern-${this.uid}-${this._tick}`;
  }
  /** Destroys the fill pattern, releasing resources. This will also destroy the internal texture. */
  destroy() {
    this.texture.destroy(true);
    this.texture = null;
  }
}

exports.FillPattern = FillPattern;
//# sourceMappingURL=FillPattern.js.map
