"use strict";
function addProgramDefines(src, isES300, isFragment) {
  if (isES300) return src;
  if (isFragment) {
    src = src.replace("out vec4 finalColor;", "");
    return `

        #ifdef GL_ES // This checks if it is WebGL1
        #define in varying
        #define finalColor gl_FragColor
        #define texture texture2D
        #endif
        ${src}
        `;
  }
  return `

        #ifdef GL_ES // This checks if it is WebGL1
        #define in attribute
        #define out varying
        #endif
        ${src}
        `;
}

export { addProgramDefines };
//# sourceMappingURL=addProgramDefines.mjs.map
