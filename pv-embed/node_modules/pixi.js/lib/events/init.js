'use strict';

var Extensions = require('../extensions/Extensions.js');
var Container = require('../scene/container/Container.js');
var EventSystem = require('./EventSystem.js');
var FederatedEventTarget = require('./FederatedEventTarget.js');

"use strict";
Extensions.extensions.add(EventSystem.EventSystem);
Extensions.extensions.mixin(Container.Container, FederatedEventTarget.FederatedContainer);
//# sourceMappingURL=init.js.map
