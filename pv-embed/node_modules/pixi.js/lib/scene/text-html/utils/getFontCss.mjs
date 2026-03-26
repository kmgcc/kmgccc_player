import { Cache } from '../../../assets/cache/Cache.mjs';
import { loadFontCSS } from './loadFontCSS.mjs';

"use strict";
const FontStylePromiseCache = /* @__PURE__ */ new Map();
async function getFontCss(fontFamilies) {
  const fontPromises = fontFamilies.filter((fontFamily) => Cache.has(`${fontFamily}-and-url`)).map((fontFamily) => {
    if (!FontStylePromiseCache.has(fontFamily)) {
      const { entries } = Cache.get(`${fontFamily}-and-url`);
      const promises = [];
      entries.forEach((entry) => {
        const url = entry.url;
        const faces = entry.faces;
        const out = faces.map((face) => ({ weight: face.weight, style: face.style }));
        promises.push(
          ...out.map(
            (style) => loadFontCSS(
              {
                fontWeight: style.weight,
                fontStyle: style.style,
                fontFamily
              },
              url
            )
          )
        );
      });
      FontStylePromiseCache.set(
        fontFamily,
        Promise.all(promises).then((css) => css.join("\n"))
      );
    }
    return FontStylePromiseCache.get(fontFamily);
  });
  return (await Promise.all(fontPromises)).join("\n");
}

export { FontStylePromiseCache, getFontCss };
//# sourceMappingURL=getFontCss.mjs.map
