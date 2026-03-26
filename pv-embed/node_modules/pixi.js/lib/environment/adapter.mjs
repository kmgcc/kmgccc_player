import { BrowserAdapter } from '../environment-browser/BrowserAdapter.mjs';

"use strict";
let currentAdapter = BrowserAdapter;
const DOMAdapter = {
  /**
   * Returns the current adapter.
   * @returns {environment.Adapter} The current adapter.
   */
  get() {
    return currentAdapter;
  },
  /**
   * Sets the current adapter.
   * @param adapter - The new adapter.
   */
  set(adapter) {
    currentAdapter = adapter;
  }
};

export { DOMAdapter };
//# sourceMappingURL=adapter.mjs.map
