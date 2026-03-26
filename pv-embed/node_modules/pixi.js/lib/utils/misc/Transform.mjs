import { Matrix } from '../../maths/matrix/Matrix.mjs';
import { ObservablePoint } from '../../maths/point/ObservablePoint.mjs';

"use strict";
class Transform {
  /**
   * @param options - Options for the transform.
   * @param options.matrix - The matrix to use.
   * @param options.observer - The observer to use.
   */
  constructor({ matrix, observer } = {}) {
    this.dirty = true;
    this._matrix = matrix ?? new Matrix();
    this.observer = observer;
    this.position = new ObservablePoint(this, 0, 0);
    this.scale = new ObservablePoint(this, 1, 1);
    this.pivot = new ObservablePoint(this, 0, 0);
    this.skew = new ObservablePoint(this, 0, 0);
    this._rotation = 0;
    this._cx = 1;
    this._sx = 0;
    this._cy = 0;
    this._sy = 1;
  }
  /**
   * The transformation matrix computed from the transform's properties.
   * Combines position, scale, rotation, skew, and pivot into a single matrix.
   * @example
   * ```ts
   * // Get current matrix
   * const matrix = transform.matrix;
   * console.log(matrix.toString());
   * ```
   * @readonly
   * @see {@link Matrix} For matrix operations
   * @see {@link Transform.setFromMatrix} For setting transform from matrix
   */
  get matrix() {
    const lt = this._matrix;
    if (!this.dirty) return lt;
    lt.a = this._cx * this.scale.x;
    lt.b = this._sx * this.scale.x;
    lt.c = this._cy * this.scale.y;
    lt.d = this._sy * this.scale.y;
    lt.tx = this.position.x - (this.pivot.x * lt.a + this.pivot.y * lt.c);
    lt.ty = this.position.y - (this.pivot.x * lt.b + this.pivot.y * lt.d);
    this.dirty = false;
    return lt;
  }
  /**
   * Called when a value changes.
   * @param point
   * @internal
   */
  _onUpdate(point) {
    this.dirty = true;
    if (point === this.skew) {
      this.updateSkew();
    }
    this.observer?._onUpdate(this);
  }
  /** Called when the skew or the rotation changes. */
  updateSkew() {
    this._cx = Math.cos(this._rotation + this.skew.y);
    this._sx = Math.sin(this._rotation + this.skew.y);
    this._cy = -Math.sin(this._rotation - this.skew.x);
    this._sy = Math.cos(this._rotation - this.skew.x);
    this.dirty = true;
  }
  toString() {
    return `[pixi.js/math:Transform position=(${this.position.x}, ${this.position.y}) rotation=${this.rotation} scale=(${this.scale.x}, ${this.scale.y}) skew=(${this.skew.x}, ${this.skew.y}) ]`;
  }
  /**
   * Decomposes a matrix and sets the transforms properties based on it.
   * @example
   * ```ts
   * // Basic matrix decomposition
   * const transform = new Transform();
   * const matrix = new Matrix()
   *     .translate(100, 100)
   *     .rotate(Math.PI / 4)
   *     .scale(2, 2);
   *
   * transform.setFromMatrix(matrix);
   * console.log(transform.position.x); // 100
   * console.log(transform.rotation); // ~0.785 (π/4)
   * ```
   * @param matrix - The matrix to decompose
   * @see {@link Matrix#decompose} For the decomposition logic
   * @see {@link Transform#matrix} For getting the current matrix
   */
  setFromMatrix(matrix) {
    matrix.decompose(this);
    this.dirty = true;
  }
  /**
   * The rotation of the object in radians.
   * @example
   * ```ts
   * // Basic rotation
   * transform.rotation = Math.PI / 4; // 45 degrees
   *
   * // Rotate around pivot point
   * transform.pivot.set(50, 50);
   * transform.rotation = Math.PI; // 180 degrees around pivot
   *
   * // Animate rotation
   * app.ticker.add(() => {
   *     transform.rotation += 0.1;
   * });
   * ```
   * @see {@link Transform#pivot} For rotation point
   * @see {@link Transform#skew} For skew effects
   */
  get rotation() {
    return this._rotation;
  }
  set rotation(value) {
    if (this._rotation !== value) {
      this._rotation = value;
      this._onUpdate(this.skew);
    }
  }
}

export { Transform };
//# sourceMappingURL=Transform.mjs.map
