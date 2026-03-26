'use strict';

var Matrix = require('../../../maths/matrix/Matrix.js');
var matrixAndBoundsPool = require('./utils/matrixAndBoundsPool.js');

"use strict";
function getGlobalBounds(target, skipUpdateTransform, bounds) {
  bounds.clear();
  let parentTransform;
  let pooledMatrix;
  if (target.parent) {
    if (!skipUpdateTransform) {
      pooledMatrix = matrixAndBoundsPool.matrixPool.get().identity();
      parentTransform = updateTransformBackwards(target, pooledMatrix);
    } else {
      parentTransform = target.parent.worldTransform;
    }
  } else {
    parentTransform = Matrix.Matrix.IDENTITY;
  }
  _getGlobalBounds(target, bounds, parentTransform, skipUpdateTransform);
  if (pooledMatrix) {
    matrixAndBoundsPool.matrixPool.return(pooledMatrix);
  }
  if (!bounds.isValid) {
    bounds.set(0, 0, 0, 0);
  }
  return bounds;
}
function _getGlobalBounds(target, bounds, parentTransform, skipUpdateTransform) {
  if (!target.visible || !target.measurable) return;
  let worldTransform;
  if (!skipUpdateTransform) {
    target.updateLocalTransform();
    worldTransform = matrixAndBoundsPool.matrixPool.get();
    worldTransform.appendFrom(target.localTransform, parentTransform);
  } else {
    worldTransform = target.worldTransform;
  }
  const parentBounds = bounds;
  const preserveBounds = !!target.effects.length;
  if (preserveBounds) {
    bounds = matrixAndBoundsPool.boundsPool.get().clear();
  }
  if (target.boundsArea) {
    bounds.addRect(target.boundsArea, worldTransform);
  } else {
    const renderableBounds = target.bounds;
    if (renderableBounds && !renderableBounds.isEmpty()) {
      bounds.matrix = worldTransform;
      bounds.addBounds(renderableBounds);
    }
    for (let i = 0; i < target.children.length; i++) {
      _getGlobalBounds(target.children[i], bounds, worldTransform, skipUpdateTransform);
    }
  }
  if (preserveBounds) {
    for (let i = 0; i < target.effects.length; i++) {
      target.effects[i].addBounds?.(bounds);
    }
    parentBounds.addBounds(bounds, Matrix.Matrix.IDENTITY);
    matrixAndBoundsPool.boundsPool.return(bounds);
  }
  if (!skipUpdateTransform) {
    matrixAndBoundsPool.matrixPool.return(worldTransform);
  }
}
function updateTransformBackwards(target, parentTransform) {
  const parent = target.parent;
  if (parent) {
    updateTransformBackwards(parent, parentTransform);
    parent.updateLocalTransform();
    parentTransform.append(parent.localTransform);
  }
  return parentTransform;
}

exports.getGlobalBounds = getGlobalBounds;
exports.updateTransformBackwards = updateTransformBackwards;
//# sourceMappingURL=getGlobalBounds.js.map
