import { FederatedMouseEvent } from './FederatedMouseEvent.mjs';

"use strict";
class FederatedPointerEvent extends FederatedMouseEvent {
  constructor() {
    super(...arguments);
    /**
     * The width of the pointer's contact along the x-axis, measured in CSS pixels.
     * radiusX of TouchEvents will be represented by this value.
     * @see https://developer.mozilla.org/en-US/docs/Web/API/PointerEvent/width
     */
    this.width = 0;
    /**
     * The height of the pointer's contact along the y-axis, measured in CSS pixels.
     * radiusY of TouchEvents will be represented by this value.
     * @see https://developer.mozilla.org/en-US/docs/Web/API/PointerEvent/height
     */
    this.height = 0;
    /**
     * Indicates whether or not the pointer device that created the event is the primary pointer.
     * @see https://developer.mozilla.org/en-US/docs/Web/API/PointerEvent/isPrimary
     */
    this.isPrimary = false;
  }
  /**
   * Only included for completeness for now
   * @ignore
   */
  getCoalescedEvents() {
    if (this.type === "pointermove" || this.type === "mousemove" || this.type === "touchmove") {
      return [this];
    }
    return [];
  }
  /**
   * Only included for completeness for now
   * @ignore
   */
  getPredictedEvents() {
    throw new Error("getPredictedEvents is not supported!");
  }
}

export { FederatedPointerEvent };
//# sourceMappingURL=FederatedPointerEvent.mjs.map
