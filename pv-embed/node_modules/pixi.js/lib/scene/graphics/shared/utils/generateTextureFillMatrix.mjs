import { Matrix } from '../../../../maths/matrix/Matrix.mjs';
import { Rectangle } from '../../../../maths/shapes/Rectangle.mjs';
import { FillGradient } from '../fill/FillGradient.mjs';

"use strict";
const tempTextureMatrix = new Matrix();
const tempRect = new Rectangle();
function generateTextureMatrix(out, style, shape, matrix) {
  const textureMatrix = style.matrix ? out.copyFrom(style.matrix).invert() : out.identity();
  if (style.textureSpace === "local") {
    const bounds = shape.getBounds(tempRect);
    if (style.width) {
      bounds.pad(style.width);
    }
    const { x: tx, y: ty } = bounds;
    const sx = 1 / bounds.width;
    const sy = 1 / bounds.height;
    const mTx = -tx * sx;
    const mTy = -ty * sy;
    const a1 = textureMatrix.a;
    const b1 = textureMatrix.b;
    const c1 = textureMatrix.c;
    const d1 = textureMatrix.d;
    textureMatrix.a *= sx;
    textureMatrix.b *= sx;
    textureMatrix.c *= sy;
    textureMatrix.d *= sy;
    textureMatrix.tx = mTx * a1 + mTy * c1 + textureMatrix.tx;
    textureMatrix.ty = mTx * b1 + mTy * d1 + textureMatrix.ty;
  } else {
    textureMatrix.translate(style.texture.frame.x, style.texture.frame.y);
    textureMatrix.scale(1 / style.texture.source.width, 1 / style.texture.source.height);
  }
  const sourceStyle = style.texture.source.style;
  if (!(style.fill instanceof FillGradient) && sourceStyle.addressMode === "clamp-to-edge") {
    sourceStyle.addressMode = "repeat";
    sourceStyle.update();
  }
  if (matrix) {
    textureMatrix.append(tempTextureMatrix.copyFrom(matrix).invert());
  }
  return textureMatrix;
}

export { generateTextureMatrix };
//# sourceMappingURL=generateTextureFillMatrix.mjs.map
