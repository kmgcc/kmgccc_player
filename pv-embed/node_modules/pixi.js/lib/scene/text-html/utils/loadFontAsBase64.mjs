import { DOMAdapter } from '../../../environment/adapter.mjs';

"use strict";
async function loadFontAsBase64(url) {
  const response = await DOMAdapter.get().fetch(url);
  const blob = await response.blob();
  const reader = new FileReader();
  const dataSrc = await new Promise((resolve, reject) => {
    reader.onloadend = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
  return dataSrc;
}

export { loadFontAsBase64 };
//# sourceMappingURL=loadFontAsBase64.mjs.map
