'use strict';

var Matrix = require('../maths/matrix/Matrix.js');
var Rectangle = require('../maths/shapes/Rectangle.js');
var Bounds = require('../scene/container/bounds/Bounds.js');
var getGlobalBounds = require('../scene/container/bounds/getGlobalBounds.js');

"use strict";
const tempBounds = new Bounds.Bounds();
const tempMatrix = new Matrix.Matrix();
const tempRectangle = new Rectangle.Rectangle();
const _Culler = class _Culler {
  /**
   * Culls the children of a specific container based on the given view rectangle.
   * This determines which objects should be rendered and which can be skipped.
   * @param container - The container to cull. Must be a Container instance.
   * @param view - The view rectangle that defines the visible area
   * @param skipUpdateTransform - Whether to skip updating transforms for better performance
   * @example
   * ```ts
   * // Basic culling with view bounds
   * const culler = new Culler();
   * culler.cull(stage, {
   *     x: 0,
   *     y: 0,
   *     width: 800,
   *     height: 600
   * });
   *
   * // Culling to renderer screen
   * culler.cull(stage, renderer.screen, false);
   * ```
   * @remarks
   * - Recursively processes all cullable children
   * - Uses cullArea if defined, otherwise calculates bounds
   * - Performance depends on scene complexity
   * @see {@link CullingMixinConstructor.cullable} For enabling culling on objects
   * @see {@link CullingMixinConstructor.cullArea} For custom culling boundaries
   */
  cull(container, view, skipUpdateTransform = true) {
    this._cullRecursive(container, view, skipUpdateTransform);
  }
  _cullRecursive(container, view, skipUpdateTransform = true) {
    if (container.cullable && container.measurable && container.includeInBuild) {
      if (container.cullArea) {
        tempRectangle.x = view.x;
        tempRectangle.y = view.y;
        tempRectangle.width = view.width;
        tempRectangle.height = view.height;
        const transform = skipUpdateTransform ? container.worldTransform : container.getGlobalTransform(tempMatrix, skipUpdateTransform);
        container.culled = !tempRectangle.intersects(
          container.cullArea,
          transform
        );
      } else {
        const bounds = getGlobalBounds.getGlobalBounds(container, skipUpdateTransform, tempBounds);
        container.culled = bounds.x >= view.x + view.width || bounds.y >= view.y + view.height || bounds.x + bounds.width <= view.x || bounds.y + bounds.height <= view.y;
      }
    } else {
      container.culled = false;
    }
    if (!container.cullableChildren || container.culled || !container.renderable || !container.measurable || !container.includeInBuild) return;
    for (let i = 0; i < container.children.length; i++) {
      this._cullRecursive(container.children[i], view, skipUpdateTransform);
    }
  }
};
/**
 * A shared instance of the Culler class. Provides a global culler instance for convenience.
 * @example
 * ```ts
 * // Use the shared instance instead of creating a new one
 * Culler.shared.cull(stage, {
 *     x: 0,
 *     y: 0,
 *     width: 800,
 *     height: 600
 * });
 * ```
 * @see {@link CullerPlugin} For automatic culling using this instance
 */
_Culler.shared = new _Culler();
let Culler = _Culler;

exports.Culler = Culler;
//# sourceMappingURL=Culler.js.map
