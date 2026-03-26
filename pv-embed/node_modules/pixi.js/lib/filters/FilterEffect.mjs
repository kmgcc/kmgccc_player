"use strict";
class FilterEffect {
  constructor() {
    /** the pipe that knows how to handle this effect */
    this.pipe = "filter";
    /** the priority of this effect */
    this.priority = 1;
  }
  destroy() {
    for (let i = 0; i < this.filters.length; i++) {
      this.filters[i].destroy();
    }
    this.filters = null;
    this.filterArea = null;
  }
}

export { FilterEffect };
//# sourceMappingURL=FilterEffect.mjs.map
