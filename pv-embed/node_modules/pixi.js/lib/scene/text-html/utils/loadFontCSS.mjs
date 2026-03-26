import { loadFontAsBase64 } from './loadFontAsBase64.mjs';

"use strict";
async function loadFontCSS(style, url) {
  const dataSrc = await loadFontAsBase64(url);
  return `@font-face {
        font-family: "${style.fontFamily}";
        font-weight: ${style.fontWeight};
        font-style: ${style.fontStyle};
        src: url('${dataSrc}');
    }`;
}

export { loadFontCSS };
//# sourceMappingURL=loadFontCSS.mjs.map
