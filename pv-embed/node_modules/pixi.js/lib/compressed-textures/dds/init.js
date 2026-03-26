'use strict';

var Extensions = require('../../extensions/Extensions.js');
var detectCompressed = require('../shared/detectCompressed.js');
var resolveCompressedTextureUrl = require('../shared/resolveCompressedTextureUrl.js');
var loadDDS = require('./loadDDS.js');

"use strict";
Extensions.extensions.add(loadDDS.loadDDS, detectCompressed.detectCompressed, resolveCompressedTextureUrl.resolveCompressedTextureUrl);
//# sourceMappingURL=init.js.map
