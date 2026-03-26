'use strict';

var Extensions = require('../../extensions/Extensions.js');
var CanvasTextPipe = require('./canvas/CanvasTextPipe.js');
var CanvasTextSystem = require('./canvas/CanvasTextSystem.js');
var GpuTextSystem = require('./shared/GpuTextSystem.js');

"use strict";
Extensions.extensions.add(CanvasTextSystem.CanvasRendererTextSystem);
Extensions.extensions.add(GpuTextSystem.CanvasTextSystem);
Extensions.extensions.add(CanvasTextPipe.CanvasTextPipe);
//# sourceMappingURL=init.js.map
