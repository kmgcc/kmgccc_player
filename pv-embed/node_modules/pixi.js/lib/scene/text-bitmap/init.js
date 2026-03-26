'use strict';

var Extensions = require('../../extensions/Extensions.js');
var CanvasBitmapTextPipe = require('./CanvasBitmapTextPipe.js');
var GpuBitmapTextPipe = require('./GpuBitmapTextPipe.js');

"use strict";
Extensions.extensions.add(CanvasBitmapTextPipe.CanvasBitmapTextPipe);
Extensions.extensions.add(GpuBitmapTextPipe.BitmapTextPipe);
//# sourceMappingURL=init.js.map
