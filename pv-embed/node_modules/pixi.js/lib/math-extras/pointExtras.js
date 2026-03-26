'use strict';

var Point = require('../maths/point/Point.js');

"use strict";
const pointExtraMixins = {
  add(other, outPoint) {
    if (!outPoint) {
      outPoint = new Point.Point();
    }
    outPoint.x = this.x + other.x;
    outPoint.y = this.y + other.y;
    return outPoint;
  },
  subtract(other, outPoint) {
    if (!outPoint) {
      outPoint = new Point.Point();
    }
    outPoint.x = this.x - other.x;
    outPoint.y = this.y - other.y;
    return outPoint;
  },
  multiply(other, outPoint) {
    if (!outPoint) {
      outPoint = new Point.Point();
    }
    outPoint.x = this.x * other.x;
    outPoint.y = this.y * other.y;
    return outPoint;
  },
  multiplyScalar(scalar, outPoint) {
    if (!outPoint) {
      outPoint = new Point.Point();
    }
    outPoint.x = this.x * scalar;
    outPoint.y = this.y * scalar;
    return outPoint;
  },
  dot(other) {
    return this.x * other.x + this.y * other.y;
  },
  cross(other) {
    return this.x * other.y - this.y * other.x;
  },
  normalize(outPoint) {
    if (!outPoint) {
      outPoint = new Point.Point();
    }
    const magnitude = Math.sqrt(this.x * this.x + this.y * this.y);
    outPoint.x = this.x / magnitude;
    outPoint.y = this.y / magnitude;
    return outPoint;
  },
  magnitude() {
    return Math.sqrt(this.x * this.x + this.y * this.y);
  },
  magnitudeSquared() {
    return this.x * this.x + this.y * this.y;
  },
  project(onto, outPoint) {
    if (!outPoint) {
      outPoint = new Point.Point();
    }
    const normalizedScalarProjection = (this.x * onto.x + this.y * onto.y) / (onto.x * onto.x + onto.y * onto.y);
    outPoint.x = onto.x * normalizedScalarProjection;
    outPoint.y = onto.y * normalizedScalarProjection;
    return outPoint;
  },
  reflect(normal, outPoint) {
    if (!outPoint) {
      outPoint = new Point.Point();
    }
    const dotProduct = this.x * normal.x + this.y * normal.y;
    outPoint.x = this.x - 2 * dotProduct * normal.x;
    outPoint.y = this.y - 2 * dotProduct * normal.y;
    return outPoint;
  },
  rotate(radians, outPoint) {
    outPoint ?? (outPoint = new Point.Point());
    const cosTheta = Math.cos(radians);
    const sinTheta = Math.sin(radians);
    outPoint.x = this.x * cosTheta - this.y * sinTheta;
    outPoint.y = this.x * sinTheta + this.y * cosTheta;
    return outPoint;
  }
};

exports.pointExtraMixins = pointExtraMixins;
//# sourceMappingURL=pointExtras.js.map
