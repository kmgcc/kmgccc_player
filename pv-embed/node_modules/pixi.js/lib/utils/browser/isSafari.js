'use strict';

var adapter = require('../../environment/adapter.js');

"use strict";
function isSafari() {
  const { userAgent } = adapter.DOMAdapter.get().getNavigator();
  return /^((?!chrome|android).)*safari/i.test(userAgent);
}

exports.isSafari = isSafari;
//# sourceMappingURL=isSafari.js.map
