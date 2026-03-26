'use strict';

var Extensions = require('../extensions/Extensions.js');
var AlphaMask = require('./mask/alpha/AlphaMask.js');
var ColorMask = require('./mask/color/ColorMask.js');
var StencilMask = require('./mask/stencil/StencilMask.js');
var BufferImageSource = require('./renderers/shared/texture/sources/BufferImageSource.js');
var CanvasSource = require('./renderers/shared/texture/sources/CanvasSource.js');
var ImageSource = require('./renderers/shared/texture/sources/ImageSource.js');
var VideoSource = require('./renderers/shared/texture/sources/VideoSource.js');
require('./renderers/shared/texture/utils/textureFrom.js');
require('./mask/MaskEffectManager.js');

"use strict";
Extensions.extensions.add(AlphaMask.AlphaMask, ColorMask.ColorMask, StencilMask.StencilMask, VideoSource.VideoSource, ImageSource.ImageSource, CanvasSource.CanvasSource, BufferImageSource.BufferImageSource);
//# sourceMappingURL=init.js.map
