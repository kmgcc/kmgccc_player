'use strict';

var BrowserAdapter = require('../environment-browser/BrowserAdapter.js');

"use strict";
let currentAdapter = BrowserAdapter.BrowserAdapter;
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

exports.DOMAdapter = DOMAdapter;
//# sourceMappingURL=adapter.js.map
