import { UPDATE_PRIORITY } from '../ticker/const.mjs';
import { Ticker } from '../ticker/Ticker.mjs';

"use strict";
class CanvasObserver {
  constructor(options) {
    /** A cached value of the last transform applied to the DOM element. */
    this._lastTransform = "";
    /** A ResizeObserver instance to observe changes in the canvas size. */
    this._observer = null;
    /** A flag to indicate whether the observer is attached to the Ticker for continuous updates. */
    this._tickerAttached = false;
    /**
     * Updates the transform of the DOM element based on the canvas size and position.
     * This method calculates the scale and translation needed to keep the DOM element in sync with the canvas.
     */
    this.updateTranslation = () => {
      if (!this._canvas) return;
      const rect = this._canvas.getBoundingClientRect();
      const contentWidth = this._canvas.width;
      const contentHeight = this._canvas.height;
      const sx = rect.width / contentWidth * this._renderer.resolution;
      const sy = rect.height / contentHeight * this._renderer.resolution;
      const tx = rect.left;
      const ty = rect.top;
      const newTransform = `translate(${tx}px, ${ty}px) scale(${sx}, ${sy})`;
      if (newTransform !== this._lastTransform) {
        this._domElement.style.transform = newTransform;
        this._lastTransform = newTransform;
      }
    };
    this._domElement = options.domElement;
    this._renderer = options.renderer;
    if (globalThis.OffscreenCanvas && this._renderer.canvas instanceof OffscreenCanvas) return;
    this._canvas = this._renderer.canvas;
    this._attachObserver();
  }
  /** The canvas element that this CanvasObserver is associated with. */
  get canvas() {
    return this._canvas;
  }
  /** Attaches the DOM element to the canvas parent if it is not already attached. */
  ensureAttached() {
    if (!this._domElement.parentNode && this._canvas.parentNode) {
      this._canvas.parentNode.appendChild(this._domElement);
      this.updateTranslation();
    }
  }
  /** Sets up a ResizeObserver if available. This ensures that the DOM element is kept in sync with the canvas size . */
  _attachObserver() {
    if ("ResizeObserver" in globalThis) {
      if (this._observer) {
        this._observer.disconnect();
        this._observer = null;
      }
      this._observer = new ResizeObserver((entries) => {
        for (const entry of entries) {
          if (entry.target !== this._canvas) {
            continue;
          }
          const contentWidth = this.canvas.width;
          const contentHeight = this.canvas.height;
          const sx = entry.contentRect.width / contentWidth * this._renderer.resolution;
          const sy = entry.contentRect.height / contentHeight * this._renderer.resolution;
          const needsUpdate = this._lastScaleX !== sx || this._lastScaleY !== sy;
          if (needsUpdate) {
            this.updateTranslation();
            this._lastScaleX = sx;
            this._lastScaleY = sy;
          }
        }
      });
      this._observer.observe(this._canvas);
    } else if (!this._tickerAttached) {
      Ticker.shared.add(this.updateTranslation, this, UPDATE_PRIORITY.HIGH);
    }
  }
  /** Destroys the CanvasObserver instance, cleaning up observers and Ticker. */
  destroy() {
    if (this._observer) {
      this._observer.disconnect();
      this._observer = null;
    } else if (this._tickerAttached) {
      Ticker.shared.remove(this.updateTranslation);
    }
    this._domElement = null;
    this._renderer = null;
    this._canvas = null;
    this._tickerAttached = false;
    this._lastTransform = "";
    this._lastScaleX = null;
    this._lastScaleY = null;
  }
}

export { CanvasObserver };
//# sourceMappingURL=CanvasObserver.mjs.map
