'use strict';

var Extensions = require('../../extensions/Extensions.js');
var detectBasis = require('./detectBasis.js');
var loadBasis = require('./loadBasis.js');

"use strict";
Extensions.extensions.add(loadBasis.loadBasis, detectBasis.detectBasis);
//# sourceMappingURL=init.js.map
