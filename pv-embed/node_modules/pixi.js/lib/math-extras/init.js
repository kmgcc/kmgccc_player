'use strict';

var ObservablePoint = require('../maths/point/ObservablePoint.js');
var Point = require('../maths/point/Point.js');
var Rectangle = require('../maths/shapes/Rectangle.js');
var pointExtras = require('./pointExtras.js');
var rectangleExtras = require('./rectangleExtras.js');

"use strict";
Object.assign(Point.Point.prototype, pointExtras.pointExtraMixins);
Object.assign(ObservablePoint.ObservablePoint.prototype, pointExtras.pointExtraMixins);
Object.assign(Rectangle.Rectangle.prototype, rectangleExtras.rectangleExtraMixins);
//# sourceMappingURL=init.js.map
