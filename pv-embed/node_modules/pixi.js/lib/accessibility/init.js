'use strict';

var Extensions = require('../extensions/Extensions.js');
var Container = require('../scene/container/Container.js');
var AccessibilitySystem = require('./AccessibilitySystem.js');
var accessibilityTarget = require('./accessibilityTarget.js');

"use strict";
Extensions.extensions.add(AccessibilitySystem.AccessibilitySystem);
Extensions.extensions.mixin(Container.Container, accessibilityTarget.accessibilityTarget);
//# sourceMappingURL=init.js.map
