'use strict';

var Circle = require('../../../../maths/shapes/Circle.js');
var Ellipse = require('../../../../maths/shapes/Ellipse.js');
var Polygon = require('../../../../maths/shapes/Polygon.js');
var Rectangle = require('../../../../maths/shapes/Rectangle.js');
var RoundedRectangle = require('../../../../maths/shapes/RoundedRectangle.js');
var Bounds = require('../../../container/bounds/Bounds.js');
var buildAdaptiveBezier = require('../buildCommands/buildAdaptiveBezier.js');
var buildAdaptiveQuadratic = require('../buildCommands/buildAdaptiveQuadratic.js');
var buildArc = require('../buildCommands/buildArc.js');
var buildArcTo = require('../buildCommands/buildArcTo.js');
var buildArcToSvg = require('../buildCommands/buildArcToSvg.js');
var roundShape = require('./roundShape.js');

"use strict";
const tempRectangle = new Rectangle.Rectangle();
class ShapePath {
  constructor(graphicsPath2D) {
    /** The list of shape primitives that make up the path. */
    this.shapePrimitives = [];
    this._currentPoly = null;
    this._bounds = new Bounds.Bounds();
    this._graphicsPath2D = graphicsPath2D;
    this.signed = graphicsPath2D.checkForHoles;
  }
  /**
   * Sets the starting point for a new sub-path. Any subsequent drawing commands are considered part of this path.
   * @param x - The x-coordinate for the starting point.
   * @param y - The y-coordinate for the starting point.
   * @returns The instance of the current object for chaining.
   */
  moveTo(x, y) {
    this.startPoly(x, y);
    return this;
  }
  /**
   * Connects the current point to a new point with a straight line. This method updates the current path.
   * @param x - The x-coordinate of the new point to connect to.
   * @param y - The y-coordinate of the new point to connect to.
   * @returns The instance of the current object for chaining.
   */
  lineTo(x, y) {
    this._ensurePoly();
    const points = this._currentPoly.points;
    const fromX = points[points.length - 2];
    const fromY = points[points.length - 1];
    if (fromX !== x || fromY !== y) {
      points.push(x, y);
    }
    return this;
  }
  /**
   * Adds an arc to the path. The arc is centered at (x, y)
   *  position with radius `radius` starting at `startAngle` and ending at `endAngle`.
   * @param x - The x-coordinate of the arc's center.
   * @param y - The y-coordinate of the arc's center.
   * @param radius - The radius of the arc.
   * @param startAngle - The starting angle of the arc, in radians.
   * @param endAngle - The ending angle of the arc, in radians.
   * @param counterclockwise - Specifies whether the arc should be drawn in the anticlockwise direction. False by default.
   * @returns The instance of the current object for chaining.
   */
  arc(x, y, radius, startAngle, endAngle, counterclockwise) {
    this._ensurePoly(false);
    const points = this._currentPoly.points;
    buildArc.buildArc(points, x, y, radius, startAngle, endAngle, counterclockwise);
    return this;
  }
  /**
   * Adds an arc to the path with the arc tangent to the line joining two specified points.
   * The arc radius is specified by `radius`.
   * @param x1 - The x-coordinate of the first point.
   * @param y1 - The y-coordinate of the first point.
   * @param x2 - The x-coordinate of the second point.
   * @param y2 - The y-coordinate of the second point.
   * @param radius - The radius of the arc.
   * @returns The instance of the current object for chaining.
   */
  arcTo(x1, y1, x2, y2, radius) {
    this._ensurePoly();
    const points = this._currentPoly.points;
    buildArcTo.buildArcTo(points, x1, y1, x2, y2, radius);
    return this;
  }
  /**
   * Adds an SVG-style arc to the path, allowing for elliptical arcs based on the SVG spec.
   * @param rx - The x-radius of the ellipse.
   * @param ry - The y-radius of the ellipse.
   * @param xAxisRotation - The rotation of the ellipse's x-axis relative
   * to the x-axis of the coordinate system, in degrees.
   * @param largeArcFlag - Determines if the arc should be greater than or less than 180 degrees.
   * @param sweepFlag - Determines if the arc should be swept in a positive angle direction.
   * @param x - The x-coordinate of the arc's end point.
   * @param y - The y-coordinate of the arc's end point.
   * @returns The instance of the current object for chaining.
   */
  arcToSvg(rx, ry, xAxisRotation, largeArcFlag, sweepFlag, x, y) {
    const points = this._currentPoly.points;
    buildArcToSvg.buildArcToSvg(
      points,
      this._currentPoly.lastX,
      this._currentPoly.lastY,
      x,
      y,
      rx,
      ry,
      xAxisRotation,
      largeArcFlag,
      sweepFlag
    );
    return this;
  }
  /**
   * Adds a cubic Bezier curve to the path.
   * It requires three points: the first two are control points and the third one is the end point.
   * The starting point is the last point in the current path.
   * @param cp1x - The x-coordinate of the first control point.
   * @param cp1y - The y-coordinate of the first control point.
   * @param cp2x - The x-coordinate of the second control point.
   * @param cp2y - The y-coordinate of the second control point.
   * @param x - The x-coordinate of the end point.
   * @param y - The y-coordinate of the end point.
   * @param smoothness - Optional parameter to adjust the smoothness of the curve.
   * @returns The instance of the current object for chaining.
   */
  bezierCurveTo(cp1x, cp1y, cp2x, cp2y, x, y, smoothness) {
    this._ensurePoly();
    const currentPoly = this._currentPoly;
    buildAdaptiveBezier.buildAdaptiveBezier(
      this._currentPoly.points,
      currentPoly.lastX,
      currentPoly.lastY,
      cp1x,
      cp1y,
      cp2x,
      cp2y,
      x,
      y,
      smoothness
    );
    return this;
  }
  /**
   * Adds a quadratic curve to the path. It requires two points: the control point and the end point.
   * The starting point is the last point in the current path.
   * @param cp1x - The x-coordinate of the control point.
   * @param cp1y - The y-coordinate of the control point.
   * @param x - The x-coordinate of the end point.
   * @param y - The y-coordinate of the end point.
   * @param smoothing - Optional parameter to adjust the smoothness of the curve.
   * @returns The instance of the current object for chaining.
   */
  quadraticCurveTo(cp1x, cp1y, x, y, smoothing) {
    this._ensurePoly();
    const currentPoly = this._currentPoly;
    buildAdaptiveQuadratic.buildAdaptiveQuadratic(
      this._currentPoly.points,
      currentPoly.lastX,
      currentPoly.lastY,
      cp1x,
      cp1y,
      x,
      y,
      smoothing
    );
    return this;
  }
  /**
   * Closes the current path by drawing a straight line back to the start.
   * If the shape is already closed or there are no points in the path, this method does nothing.
   * @returns The instance of the current object for chaining.
   */
  closePath() {
    this.endPoly(true);
    return this;
  }
  /**
   * Adds another path to the current path. This method allows for the combination of multiple paths into one.
   * @param path - The `GraphicsPath` object representing the path to add.
   * @param transform - An optional `Matrix` object to apply a transformation to the path before adding it.
   * @returns The instance of the current object for chaining.
   */
  addPath(path, transform) {
    this.endPoly();
    if (transform && !transform.isIdentity()) {
      path = path.clone(true);
      path.transform(transform);
    }
    const shapePrimitives = this.shapePrimitives;
    const start = shapePrimitives.length;
    for (let i = 0; i < path.instructions.length; i++) {
      const instruction = path.instructions[i];
      this[instruction.action](...instruction.data);
    }
    if (path.checkForHoles && shapePrimitives.length - start > 1) {
      let mainShape = null;
      for (let i = start; i < shapePrimitives.length; i++) {
        const shapePrimitive = shapePrimitives[i];
        if (shapePrimitive.shape.type === "polygon") {
          const polygon = shapePrimitive.shape;
          const mainPolygon = mainShape?.shape;
          if (mainPolygon && mainPolygon.containsPolygon(polygon)) {
            mainShape.holes || (mainShape.holes = []);
            mainShape.holes.push(shapePrimitive);
            shapePrimitives.copyWithin(i, i + 1);
            shapePrimitives.length--;
            i--;
          } else {
            mainShape = shapePrimitive;
          }
        }
      }
    }
    return this;
  }
  /**
   * Finalizes the drawing of the current path. Optionally, it can close the path.
   * @param closePath - A boolean indicating whether to close the path after finishing. False by default.
   */
  finish(closePath = false) {
    this.endPoly(closePath);
  }
  /**
   * Draws a rectangle shape. This method adds a new rectangle path to the current drawing.
   * @param x - The x-coordinate of the top-left corner of the rectangle.
   * @param y - The y-coordinate of the top-left corner of the rectangle.
   * @param w - The width of the rectangle.
   * @param h - The height of the rectangle.
   * @param transform - An optional `Matrix` object to apply a transformation to the rectangle.
   * @returns The instance of the current object for chaining.
   */
  rect(x, y, w, h, transform) {
    this.drawShape(new Rectangle.Rectangle(x, y, w, h), transform);
    return this;
  }
  /**
   * Draws a circle shape. This method adds a new circle path to the current drawing.
   * @param x - The x-coordinate of the center of the circle.
   * @param y - The y-coordinate of the center of the circle.
   * @param radius - The radius of the circle.
   * @param transform - An optional `Matrix` object to apply a transformation to the circle.
   * @returns The instance of the current object for chaining.
   */
  circle(x, y, radius, transform) {
    this.drawShape(new Circle.Circle(x, y, radius), transform);
    return this;
  }
  /**
   * Draws a polygon shape. This method allows for the creation of complex polygons by specifying a sequence of points.
   * @param points - An array of numbers, or or an array of PointData objects eg [{x,y}, {x,y}, {x,y}]
   * representing the x and y coordinates of the polygon's vertices, in sequence.
   * @param close - A boolean indicating whether to close the polygon path. True by default.
   * @param transform - An optional `Matrix` object to apply a transformation to the polygon.
   * @returns The instance of the current object for chaining.
   */
  poly(points, close, transform) {
    const polygon = new Polygon.Polygon(points);
    polygon.closePath = close;
    this.drawShape(polygon, transform);
    return this;
  }
  /**
   * Draws a regular polygon with a specified number of sides. All sides and angles are equal.
   * @param x - The x-coordinate of the center of the polygon.
   * @param y - The y-coordinate of the center of the polygon.
   * @param radius - The radius of the circumscribed circle of the polygon.
   * @param sides - The number of sides of the polygon. Must be 3 or more.
   * @param rotation - The rotation angle of the polygon, in radians. Zero by default.
   * @param transform - An optional `Matrix` object to apply a transformation to the polygon.
   * @returns The instance of the current object for chaining.
   */
  regularPoly(x, y, radius, sides, rotation = 0, transform) {
    sides = Math.max(sides | 0, 3);
    const startAngle = -1 * Math.PI / 2 + rotation;
    const delta = Math.PI * 2 / sides;
    const polygon = [];
    for (let i = 0; i < sides; i++) {
      const angle = startAngle - i * delta;
      polygon.push(
        x + radius * Math.cos(angle),
        y + radius * Math.sin(angle)
      );
    }
    this.poly(polygon, true, transform);
    return this;
  }
  /**
   * Draws a polygon with rounded corners.
   * Similar to `regularPoly` but with the ability to round the corners of the polygon.
   * @param x - The x-coordinate of the center of the polygon.
   * @param y - The y-coordinate of the center of the polygon.
   * @param radius - The radius of the circumscribed circle of the polygon.
   * @param sides - The number of sides of the polygon. Must be 3 or more.
   * @param corner - The radius of the rounding of the corners.
   * @param rotation - The rotation angle of the polygon, in radians. Zero by default.
   * @param smoothness - Optional parameter to adjust the smoothness of the rounding.
   * @returns The instance of the current object for chaining.
   */
  roundPoly(x, y, radius, sides, corner, rotation = 0, smoothness) {
    sides = Math.max(sides | 0, 3);
    if (corner <= 0) {
      return this.regularPoly(x, y, radius, sides, rotation);
    }
    const sideLength = radius * Math.sin(Math.PI / sides) - 1e-3;
    corner = Math.min(corner, sideLength);
    const startAngle = -1 * Math.PI / 2 + rotation;
    const delta = Math.PI * 2 / sides;
    const internalAngle = (sides - 2) * Math.PI / sides / 2;
    for (let i = 0; i < sides; i++) {
      const angle = i * delta + startAngle;
      const x0 = x + radius * Math.cos(angle);
      const y0 = y + radius * Math.sin(angle);
      const a1 = angle + Math.PI + internalAngle;
      const a2 = angle - Math.PI - internalAngle;
      const x1 = x0 + corner * Math.cos(a1);
      const y1 = y0 + corner * Math.sin(a1);
      const x3 = x0 + corner * Math.cos(a2);
      const y3 = y0 + corner * Math.sin(a2);
      if (i === 0) {
        this.moveTo(x1, y1);
      } else {
        this.lineTo(x1, y1);
      }
      this.quadraticCurveTo(x0, y0, x3, y3, smoothness);
    }
    return this.closePath();
  }
  /**
   * Draws a shape with rounded corners. This function supports custom radius for each corner of the shape.
   * Optionally, corners can be rounded using a quadratic curve instead of an arc, providing a different aesthetic.
   * @param points - An array of `RoundedPoint` representing the corners of the shape to draw.
   * A minimum of 3 points is required.
   * @param radius - The default radius for the corners.
   * This radius is applied to all corners unless overridden in `points`.
   * @param useQuadratic - If set to true, rounded corners are drawn using a quadraticCurve
   *  method instead of an arc method. Defaults to false.
   * @param smoothness - Specifies the smoothness of the curve when `useQuadratic` is true.
   * Higher values make the curve smoother.
   * @returns The instance of the current object for chaining.
   */
  roundShape(points, radius, useQuadratic = false, smoothness) {
    if (points.length < 3) {
      return this;
    }
    if (useQuadratic) {
      roundShape.roundedShapeQuadraticCurve(this, points, radius, smoothness);
    } else {
      roundShape.roundedShapeArc(this, points, radius);
    }
    return this.closePath();
  }
  /**
   * Draw Rectangle with fillet corners. This is much like rounded rectangle
   * however it support negative numbers as well for the corner radius.
   * @param x - Upper left corner of rect
   * @param y - Upper right corner of rect
   * @param width - Width of rect
   * @param height - Height of rect
   * @param fillet - accept negative or positive values
   */
  filletRect(x, y, width, height, fillet) {
    if (fillet === 0) {
      return this.rect(x, y, width, height);
    }
    const maxFillet = Math.min(width, height) / 2;
    const inset = Math.min(maxFillet, Math.max(-maxFillet, fillet));
    const right = x + width;
    const bottom = y + height;
    const dir = inset < 0 ? -inset : 0;
    const size = Math.abs(inset);
    return this.moveTo(x, y + size).arcTo(x + dir, y + dir, x + size, y, size).lineTo(right - size, y).arcTo(right - dir, y + dir, right, y + size, size).lineTo(right, bottom - size).arcTo(right - dir, bottom - dir, x + width - size, bottom, size).lineTo(x + size, bottom).arcTo(x + dir, bottom - dir, x, bottom - size, size).closePath();
  }
  /**
   * Draw Rectangle with chamfer corners. These are angled corners.
   * @param x - Upper left corner of rect
   * @param y - Upper right corner of rect
   * @param width - Width of rect
   * @param height - Height of rect
   * @param chamfer - non-zero real number, size of corner cutout
   * @param transform
   */
  chamferRect(x, y, width, height, chamfer, transform) {
    if (chamfer <= 0) {
      return this.rect(x, y, width, height);
    }
    const inset = Math.min(chamfer, Math.min(width, height) / 2);
    const right = x + width;
    const bottom = y + height;
    const points = [
      x + inset,
      y,
      right - inset,
      y,
      right,
      y + inset,
      right,
      bottom - inset,
      right - inset,
      bottom,
      x + inset,
      bottom,
      x,
      bottom - inset,
      x,
      y + inset
    ];
    for (let i = points.length - 1; i >= 2; i -= 2) {
      if (points[i] === points[i - 2] && points[i - 1] === points[i - 3]) {
        points.splice(i - 1, 2);
      }
    }
    return this.poly(points, true, transform);
  }
  /**
   * Draws an ellipse at the specified location and with the given x and y radii.
   * An optional transformation can be applied, allowing for rotation, scaling, and translation.
   * @param x - The x-coordinate of the center of the ellipse.
   * @param y - The y-coordinate of the center of the ellipse.
   * @param radiusX - The horizontal radius of the ellipse.
   * @param radiusY - The vertical radius of the ellipse.
   * @param transform - An optional `Matrix` object to apply a transformation to the ellipse. This can include rotations.
   * @returns The instance of the current object for chaining.
   */
  ellipse(x, y, radiusX, radiusY, transform) {
    this.drawShape(new Ellipse.Ellipse(x, y, radiusX, radiusY), transform);
    return this;
  }
  /**
   * Draws a rectangle with rounded corners.
   * The corner radius can be specified to determine how rounded the corners should be.
   * An optional transformation can be applied, which allows for rotation, scaling, and translation of the rectangle.
   * @param x - The x-coordinate of the top-left corner of the rectangle.
   * @param y - The y-coordinate of the top-left corner of the rectangle.
   * @param w - The width of the rectangle.
   * @param h - The height of the rectangle.
   * @param radius - The radius of the rectangle's corners. If not specified, corners will be sharp.
   * @param transform - An optional `Matrix` object to apply a transformation to the rectangle.
   * @returns The instance of the current object for chaining.
   */
  roundRect(x, y, w, h, radius, transform) {
    this.drawShape(new RoundedRectangle.RoundedRectangle(x, y, w, h, radius), transform);
    return this;
  }
  /**
   * Draws a given shape on the canvas.
   * This is a generic method that can draw any type of shape specified by the `ShapePrimitive` parameter.
   * An optional transformation matrix can be applied to the shape, allowing for complex transformations.
   * @param shape - The shape to draw, defined as a `ShapePrimitive` object.
   * @param matrix - An optional `Matrix` for transforming the shape. This can include rotations,
   * scaling, and translations.
   * @returns The instance of the current object for chaining.
   */
  drawShape(shape, matrix) {
    this.endPoly();
    this.shapePrimitives.push({ shape, transform: matrix });
    return this;
  }
  /**
   * Starts a new polygon path from the specified starting point.
   * This method initializes a new polygon or ends the current one if it exists.
   * @param x - The x-coordinate of the starting point of the new polygon.
   * @param y - The y-coordinate of the starting point of the new polygon.
   * @returns The instance of the current object for chaining.
   */
  startPoly(x, y) {
    let currentPoly = this._currentPoly;
    if (currentPoly) {
      this.endPoly();
    }
    currentPoly = new Polygon.Polygon();
    currentPoly.points.push(x, y);
    this._currentPoly = currentPoly;
    return this;
  }
  /**
   * Ends the current polygon path. If `closePath` is set to true,
   * the path is closed by connecting the last point to the first one.
   * This method finalizes the current polygon and prepares it for drawing or adding to the shape primitives.
   * @param closePath - A boolean indicating whether to close the polygon by connecting the last point
   *  back to the starting point. False by default.
   * @returns The instance of the current object for chaining.
   */
  endPoly(closePath = false) {
    const shape = this._currentPoly;
    if (shape && shape.points.length > 2) {
      shape.closePath = closePath;
      this.shapePrimitives.push({ shape });
    }
    this._currentPoly = null;
    return this;
  }
  _ensurePoly(start = true) {
    if (this._currentPoly) return;
    this._currentPoly = new Polygon.Polygon();
    if (start) {
      const lastShape = this.shapePrimitives[this.shapePrimitives.length - 1];
      if (lastShape) {
        let lx = lastShape.shape.x;
        let ly = lastShape.shape.y;
        if (lastShape.transform && !lastShape.transform.isIdentity()) {
          const t = lastShape.transform;
          const tempX = lx;
          lx = t.a * lx + t.c * ly + t.tx;
          ly = t.b * tempX + t.d * ly + t.ty;
        }
        this._currentPoly.points.push(lx, ly);
      } else {
        this._currentPoly.points.push(0, 0);
      }
    }
  }
  /** Builds the path. */
  buildPath() {
    const path = this._graphicsPath2D;
    this.shapePrimitives.length = 0;
    this._currentPoly = null;
    for (let i = 0; i < path.instructions.length; i++) {
      const instruction = path.instructions[i];
      this[instruction.action](...instruction.data);
    }
    this.finish();
  }
  /** Gets the bounds of the path. */
  get bounds() {
    const bounds = this._bounds;
    bounds.clear();
    const shapePrimitives = this.shapePrimitives;
    for (let i = 0; i < shapePrimitives.length; i++) {
      const shapePrimitive = shapePrimitives[i];
      const boundsRect = shapePrimitive.shape.getBounds(tempRectangle);
      if (shapePrimitive.transform) {
        bounds.addRect(boundsRect, shapePrimitive.transform);
      } else {
        bounds.addRect(boundsRect);
      }
    }
    return bounds;
  }
}

exports.ShapePath = ShapePath;
//# sourceMappingURL=ShapePath.js.map
