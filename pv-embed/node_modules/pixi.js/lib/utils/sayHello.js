'use strict';

var adapter = require('../environment/adapter.js');
var _const = require('./const.js');

"use strict";
let saidHello = false;
function sayHello(type) {
  if (saidHello) {
    return;
  }
  if (adapter.DOMAdapter.get().getNavigator().userAgent.toLowerCase().indexOf("chrome") > -1) {
    const args = [
      `%c  %c  %c  %c  %c PixiJS %c v${_const.VERSION} (${type}) http://www.pixijs.com/

`,
      "background: #E72264; padding:5px 0;",
      "background: #6CA2EA; padding:5px 0;",
      "background: #B5D33D; padding:5px 0;",
      "background: #FED23F; padding:5px 0;",
      "color: #FFFFFF; background: #E72264; padding:5px 0;",
      "color: #E72264; background: #FFFFFF; padding:5px 0;"
    ];
    globalThis.console.log(...args);
  } else if (globalThis.console) {
    globalThis.console.log(`PixiJS ${_const.VERSION} - ${type} - http://www.pixijs.com/`);
  }
  saidHello = true;
}

exports.sayHello = sayHello;
//# sourceMappingURL=sayHello.js.map
