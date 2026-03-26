'use strict';

var Extensions = require('../extensions/Extensions.js');
var GifAsset = require('./GifAsset.js');
require('./index.js');
var GifSource = require('./GifSource.js');
var GifSprite = require('./GifSprite.js');

"use strict";
Extensions.extensions.add(GifAsset.GifAsset);

exports.GifAsset = GifAsset.GifAsset;
exports.GifSource = GifSource.GifSource;
exports.GifSprite = GifSprite.GifSprite;
//# sourceMappingURL=init.js.map
