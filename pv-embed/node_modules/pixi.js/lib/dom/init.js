'use strict';

var Extensions = require('../extensions/Extensions.js');
var DOMPipe = require('./DOMPipe.js');
require('./index.js');
var CanvasObserver = require('./CanvasObserver.js');
var DOMContainer = require('./DOMContainer.js');

"use strict";
Extensions.extensions.add(DOMPipe.DOMPipe);

exports.DOMPipe = DOMPipe.DOMPipe;
exports.CanvasObserver = CanvasObserver.CanvasObserver;
exports.DOMContainer = DOMContainer.DOMContainer;
//# sourceMappingURL=init.js.map
