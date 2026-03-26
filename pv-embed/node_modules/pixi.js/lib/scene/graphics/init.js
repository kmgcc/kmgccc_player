'use strict';

var Extensions = require('../../extensions/Extensions.js');
var CanvasGraphicsContextSystem = require('./canvas/CanvasGraphicsContextSystem.js');
var CanvasGraphicsPipe = require('./canvas/CanvasGraphicsPipe.js');
var GraphicsContextSystem = require('./shared/GraphicsContextSystem.js');
var GraphicsPipe = require('./shared/GraphicsPipe.js');

"use strict";
Extensions.extensions.add(CanvasGraphicsPipe.CanvasGraphicsPipe);
Extensions.extensions.add(GraphicsPipe.GraphicsPipe);
Extensions.extensions.add(CanvasGraphicsContextSystem.CanvasGraphicsContextSystem);
Extensions.extensions.add(GraphicsContextSystem.GraphicsContextSystem);
//# sourceMappingURL=init.js.map
