import { ObservablePoint } from '../maths/point/ObservablePoint.mjs';
import { Point } from '../maths/point/Point.mjs';
import { Rectangle } from '../maths/shapes/Rectangle.mjs';
import { pointExtraMixins } from './pointExtras.mjs';
import { rectangleExtraMixins } from './rectangleExtras.mjs';

"use strict";
Object.assign(Point.prototype, pointExtraMixins);
Object.assign(ObservablePoint.prototype, pointExtraMixins);
Object.assign(Rectangle.prototype, rectangleExtraMixins);
//# sourceMappingURL=init.mjs.map
