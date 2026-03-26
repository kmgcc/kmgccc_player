'use strict';

var Extensions = require('../../extensions/Extensions.js');
var detectCompressed = require('../shared/detectCompressed.js');
var resolveCompressedTextureUrl = require('../shared/resolveCompressedTextureUrl.js');
var loadKTX = require('./loadKTX.js');

"use strict";
Extensions.extensions.add(loadKTX.loadKTX);
Extensions.extensions.add(resolveCompressedTextureUrl.resolveCompressedTextureUrl);
Extensions.extensions.add(detectCompressed.detectCompressed);
//# sourceMappingURL=init.js.map
