'use strict';

var FederatedMouseEvent = require('./FederatedMouseEvent.js');

"use strict";
class FederatedWheelEvent extends FederatedMouseEvent.FederatedMouseEvent {
  constructor() {
    super(...arguments);
    /**
     * Units specified in pixels.
     * @ignore
     */
    this.DOM_DELTA_PIXEL = 0;
    /**
     * Units specified in lines.
     * @ignore
     */
    this.DOM_DELTA_LINE = 1;
    /**
     * Units specified in pages.
     * @ignore
     */
    this.DOM_DELTA_PAGE = 2;
  }
}
/**
 * Units specified in pixels.
 * @ignore
 */
FederatedWheelEvent.DOM_DELTA_PIXEL = 0;
/**
 * Units specified in lines.
 * @ignore
 */
FederatedWheelEvent.DOM_DELTA_LINE = 1;
/**
 * Units specified in pages.
 * @ignore
 */
FederatedWheelEvent.DOM_DELTA_PAGE = 2;

exports.FederatedWheelEvent = FederatedWheelEvent;
//# sourceMappingURL=FederatedWheelEvent.js.map
