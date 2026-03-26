'use strict';

var adapter = require('../../../environment/adapter.js');

"use strict";
async function loadFontAsBase64(url) {
  const response = await adapter.DOMAdapter.get().fetch(url);
  const blob = await response.blob();
  const reader = new FileReader();
  const dataSrc = await new Promise((resolve, reject) => {
    reader.onloadend = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
  return dataSrc;
}

exports.loadFontAsBase64 = loadFontAsBase64;
//# sourceMappingURL=loadFontAsBase64.js.map
