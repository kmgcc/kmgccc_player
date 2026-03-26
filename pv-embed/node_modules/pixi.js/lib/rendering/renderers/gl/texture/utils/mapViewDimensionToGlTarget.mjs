"use strict";
function mapViewDimensionToGlTarget(gl) {
  return {
    "2d": gl.TEXTURE_2D,
    cube: gl.TEXTURE_CUBE_MAP,
    "1d": null,
    // WebGL2 only
    "3d": gl?.TEXTURE_3D || null,
    "2d-array": gl?.TEXTURE_2D_ARRAY || null,
    "cube-array": gl?.TEXTURE_CUBE_MAP_ARRAY || null
  };
}

export { mapViewDimensionToGlTarget };
//# sourceMappingURL=mapViewDimensionToGlTarget.mjs.map
