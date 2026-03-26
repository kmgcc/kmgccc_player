'use strict';

var Matrix = require('../../../maths/matrix/Matrix.js');
var matrixAndBoundsPool = require('./utils/matrixAndBoundsPool.js');

"use strict";
function getLocalBounds(target, bounds, relativeMatrix) {
  bounds.clear();
  relativeMatrix || (relativeMatrix = Matrix.Matrix.IDENTITY);
  _getLocalBounds(target, bounds, relativeMatrix, target, true);
  if (!bounds.isValid) {
    bounds.set(0, 0, 0, 0);
  }
  return bounds;
}
function _getLocalBounds(target, bounds, parentTransform, rootContainer, isRoot) {
  let relativeTransform;
  if (!isRoot) {
    if (!target.visible || !target.measurable) return;
    target.updateLocalTransform();
    const localTransform = target.localTransform;
    relativeTransform = matrixAndBoundsPool.matrixPool.get();
    relativeTransform.appendFrom(localTransform, parentTransform);
  } else {
    relativeTransform = matrixAndBoundsPool.matrixPool.get();
    relativeTransform = parentTransform.copyTo(relativeTransform);
  }
  const parentBounds = bounds;
  const preserveBounds = !!target.effects.length;
  if (preserveBounds) {
    bounds = matrixAndBoundsPool.boundsPool.get().clear();
  }
  if (target.boundsArea) {
    bounds.addRect(target.boundsArea, relativeTransform);
  } else {
    if (target.renderPipeId) {
      bounds.matrix = relativeTransform;
      bounds.addBounds(target.bounds);
    }
    const children = target.children;
    for (let i = 0; i < children.length; i++) {
      _getLocalBounds(children[i], bounds, relativeTransform, rootContainer, false);
    }
  }
  if (preserveBounds) {
    for (let i = 0; i < target.effects.length; i++) {
      target.effects[i].addLocalBounds?.(bounds, rootContainer);
    }
    parentBounds.addBounds(bounds, Matrix.Matrix.IDENTITY);
    matrixAndBoundsPool.boundsPool.return(bounds);
  }
  matrixAndBoundsPool.matrixPool.return(relativeTransform);
}

exports.getLocalBounds = getLocalBounds;
//# sourceMappingURL=getLocalBounds.js.map
