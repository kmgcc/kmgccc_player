"use strict";
function migrateFragmentFromV7toV8(fragmentShader) {
  fragmentShader = fragmentShader.replaceAll("texture2D", "texture").replaceAll("gl_FragColor", "finalColor").replaceAll("varying", "in");
  fragmentShader = `
        out vec4 finalColor;
    ${fragmentShader}
    `;
  return fragmentShader;
}

export { migrateFragmentFromV7toV8 };
//# sourceMappingURL=migrateFragmentFromV7toV8.mjs.map
