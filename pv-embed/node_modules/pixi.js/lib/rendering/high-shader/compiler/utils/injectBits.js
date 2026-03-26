'use strict';

"use strict";
function injectBits(templateSrc, fragmentParts) {
  let out = templateSrc;
  for (const i in fragmentParts) {
    const parts = fragmentParts[i];
    const toInject = parts.join("\n");
    if (toInject.length) {
      out = out.replace(`{{${i}}}`, `//-----${i} START-----//
${parts.join("\n")}
//----${i} FINISH----//`);
    } else {
      out = out.replace(`{{${i}}}`, "");
    }
  }
  return out;
}

exports.injectBits = injectBits;
//# sourceMappingURL=injectBits.js.map
