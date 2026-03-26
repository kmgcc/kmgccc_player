import { path } from '../../utils/path.mjs';

"use strict";
function checkExtension(url, extension) {
  const tempURL = url.split("?")[0];
  const ext = path.extname(tempURL).toLowerCase();
  if (Array.isArray(extension)) {
    return extension.includes(ext);
  }
  return ext === extension;
}

export { checkExtension };
//# sourceMappingURL=checkExtension.mjs.map
