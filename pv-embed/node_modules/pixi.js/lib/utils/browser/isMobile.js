'use strict';

var isMobileJs = require('ismobilejs');

"use strict";
const isMobileCall = isMobileJs.default ?? isMobileJs;
const isMobile = isMobileCall(globalThis.navigator);

exports.isMobile = isMobile;
//# sourceMappingURL=isMobile.js.map
