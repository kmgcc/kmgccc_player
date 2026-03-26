import { Color } from '../../../color/Color.mjs';
import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { mapCanvasBlendModesToPixi } from './utils/mapCanvasBlendModesToPixi.mjs';

"use strict";
const tempMatrix = new Matrix();
class CanvasContextSystem {
  /**
   * @param renderer - The owning CanvasRenderer.
   */
  constructor(renderer) {
    /** Resolution of the active context. */
    this.activeResolution = 1;
    /** The image smoothing property to toggle for this browser. */
    this.smoothProperty = "imageSmoothingEnabled";
    /** Map of Pixi blend modes to canvas composite operations. */
    this.blendModes = mapCanvasBlendModesToPixi();
    /** Current canvas blend mode. */
    this._activeBlendMode = "normal";
    /** Optional projection transform for render targets. */
    this._projTransform = null;
    /** True when external blend mode control is in use. */
    this._outerBlend = false;
    /** Tracks unsupported blend mode warnings to avoid spam. */
    this._warnedBlendModes = /* @__PURE__ */ new Set();
    this._renderer = renderer;
  }
  resolutionChange(resolution) {
    this.activeResolution = resolution;
  }
  /** Initializes the root context and smoothing flag selection. */
  init() {
    const alpha = this._renderer.background.alpha < 1;
    this.rootContext = this._renderer.canvas.getContext(
      "2d",
      { alpha }
    );
    this.activeContext = this.rootContext;
    this.activeResolution = this._renderer.resolution;
    if (!this.rootContext.imageSmoothingEnabled) {
      const rc = this.rootContext;
      if (rc.webkitImageSmoothingEnabled) {
        this.smoothProperty = "webkitImageSmoothingEnabled";
      } else if (rc.mozImageSmoothingEnabled) {
        this.smoothProperty = "mozImageSmoothingEnabled";
      } else if (rc.oImageSmoothingEnabled) {
        this.smoothProperty = "oImageSmoothingEnabled";
      } else if (rc.msImageSmoothingEnabled) {
        this.smoothProperty = "msImageSmoothingEnabled";
      }
    }
  }
  /**
   * Sets the current transform on the active context.
   * @param transform - Transform to apply.
   * @param roundPixels - Whether to round translation to integers.
   * @param localResolution - Optional local resolution multiplier.
   * @param skipGlobalTransform - If true, skip applying the global world transform matrix.
   */
  setContextTransform(transform, roundPixels, localResolution, skipGlobalTransform) {
    const globalTransform = skipGlobalTransform ? Matrix.IDENTITY : this._renderer.globalUniforms.globalUniformData?.worldTransformMatrix || Matrix.IDENTITY;
    let mat = tempMatrix;
    mat.copyFrom(globalTransform);
    mat.append(transform);
    const proj = this._projTransform;
    const contextResolution = this.activeResolution;
    localResolution = localResolution || contextResolution;
    if (proj) {
      const finalMat = Matrix.shared;
      finalMat.copyFrom(mat);
      finalMat.prepend(proj);
      mat = finalMat;
    }
    if (roundPixels) {
      this.activeContext.setTransform(
        mat.a * localResolution,
        mat.b * localResolution,
        mat.c * localResolution,
        mat.d * localResolution,
        mat.tx * contextResolution | 0,
        mat.ty * contextResolution | 0
      );
    } else {
      this.activeContext.setTransform(
        mat.a * localResolution,
        mat.b * localResolution,
        mat.c * localResolution,
        mat.d * localResolution,
        mat.tx * contextResolution,
        mat.ty * contextResolution
      );
    }
  }
  /**
   * Clears the current render target, optionally filling with a color.
   * @param clearColor - Color to fill after clearing.
   * @param alpha - Alpha override for the clear color.
   */
  clear(clearColor, alpha) {
    const context = this.activeContext;
    const renderer = this._renderer;
    context.clearRect(0, 0, renderer.width, renderer.height);
    if (clearColor) {
      const color = Color.shared.setValue(clearColor);
      context.globalAlpha = alpha ?? color.alpha;
      context.fillStyle = color.toHex();
      context.fillRect(0, 0, renderer.width, renderer.height);
      context.globalAlpha = 1;
    }
  }
  /**
   * Sets the active blend mode.
   * @param blendMode - Pixi blend mode.
   */
  setBlendMode(blendMode) {
    if (this._activeBlendMode === blendMode) return;
    this._activeBlendMode = blendMode;
    this._outerBlend = false;
    const mappedBlend = this.blendModes[blendMode];
    if (!mappedBlend) {
      if (!this._warnedBlendModes.has(blendMode)) {
        console.warn(
          `CanvasRenderer: blend mode "${blendMode}" is not supported in Canvas2D; falling back to "source-over".`
        );
        this._warnedBlendModes.add(blendMode);
      }
      this.activeContext.globalCompositeOperation = "source-over";
      return;
    }
    this.activeContext.globalCompositeOperation = mappedBlend;
  }
  /** Releases context references. */
  destroy() {
    this.rootContext = null;
    this.activeContext = null;
    this._warnedBlendModes.clear();
  }
}
/** @ignore */
CanvasContextSystem.extension = {
  type: [
    ExtensionType.CanvasSystem
  ],
  name: "canvasContext"
};

export { CanvasContextSystem };
//# sourceMappingURL=CanvasContextSystem.mjs.map
