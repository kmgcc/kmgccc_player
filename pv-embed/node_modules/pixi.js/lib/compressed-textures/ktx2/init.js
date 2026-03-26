'use strict';

var Extensions = require('../../extensions/Extensions.js');
var detectCompressed = require('../shared/detectCompressed.js');
var resolveCompressedTextureUrl = require('../shared/resolveCompressedTextureUrl.js');
var loadKTX2 = require('./loadKTX2.js');

"use strict";
Extensions.extensions.add(loadKTX2.loadKTX2);
Extensions.extensions.add(resolveCompressedTextureUrl.resolveCompressedTextureUrl);
Extensions.extensions.add(detectCompressed.detectCompressed);
//# sourceMappingURL=init.js.map
