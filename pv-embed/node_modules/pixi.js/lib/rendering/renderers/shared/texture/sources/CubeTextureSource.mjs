import { warn } from '../../../../../utils/logging/warn.mjs';
import { TextureSource } from './TextureSource.mjs';

"use strict";
class CubeTextureSource extends TextureSource {
  constructor(options) {
    const { faces, ...rest } = options;
    CubeTextureSource._validateFaces(faces);
    const first = faces.right;
    const derivedResolution = first.resolution;
    const derivedFormat = first.format;
    const derivedAlphaMode = first.alphaMode;
    const ignoredKeys = [
      "resolution",
      "format",
      "alphaMode",
      "dimensions",
      "viewDimension"
    ].filter((key) => rest[key] !== void 0);
    if (ignoredKeys.length) {
      warn(
        `[CubeTextureSource] Ignoring option(s) [${ignoredKeys.join(", ")}]; these are derived from face sources.`
      );
    }
    super({
      ...rest,
      resource: faces,
      // Keep these aligned with the face sources so any code that reads width/height works.
      width: first.width,
      height: first.height,
      dimensions: "2d",
      viewDimension: "cube",
      arrayLayerCount: 6,
      resolution: derivedResolution,
      format: derivedFormat,
      alphaMode: derivedAlphaMode
    });
    /** @internal */
    this.uploadMethodId = "cube";
    this.faces = faces;
    for (const key of Object.keys(faces)) {
      const face = faces[key];
      face.on("update", this._onFaceUpdate, this);
      face.on("resize", this._onFaceResize, this);
      face.on("unload", this._onFaceUpdate, this);
    }
  }
  destroy() {
    const faces = this.faces;
    if (faces) {
      for (const key of Object.keys(faces)) {
        const face = faces[key];
        face.off("update", this._onFaceUpdate, this);
        face.off("resize", this._onFaceResize, this);
        face.off("unload", this._onFaceUpdate, this);
      }
    }
    super.destroy();
  }
  _onFaceUpdate() {
    this.emit("update", this);
  }
  _onFaceResize(face) {
    CubeTextureSource._validateFaces(this.faces);
    this.resize(face.width, face.height, face.resolution);
  }
  static _validateFaces(faces) {
    if (!faces.right || !faces.left || !faces.top || !faces.bottom || !faces.front || !faces.back) {
      throw new Error("[CubeTextureSource] Requires { left, right, top, bottom, front, back } faces.");
    }
    const first = faces.right;
    const expectedPixelWidth = first.pixelWidth;
    const expectedPixelHeight = first.pixelHeight;
    const expectedFormat = first.format;
    const expectedAlphaMode = first.alphaMode;
    const expectedResolution = first.resolution;
    for (const key of Object.keys(faces)) {
      const face = faces[key];
      if (face.pixelWidth !== expectedPixelWidth || face.pixelHeight !== expectedPixelHeight) {
        throw new Error(`[CubeTextureSource] Face '${String(key)}' has a different size. All faces must match.`);
      }
      if (face.format !== expectedFormat) {
        throw new Error(`[CubeTextureSource] Face '${String(key)}' has a different format. All faces must match.`);
      }
      if (face.alphaMode !== expectedAlphaMode) {
        throw new Error(
          `[CubeTextureSource] Face '${String(key)}' has a different alphaMode. All faces must match.`
        );
      }
      if (face.resolution !== expectedResolution) {
        throw new Error(
          `[CubeTextureSource] Face '${String(key)}' has a different resolution. All faces must match.`
        );
      }
    }
  }
}

export { CubeTextureSource };
//# sourceMappingURL=CubeTextureSource.mjs.map
