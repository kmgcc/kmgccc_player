'use strict';

var adapter = require('../environment/adapter.js');
var Extensions = require('../extensions/Extensions.js');
var path = require('../utils/path.js');
var GifSource = require('./GifSource.js');

"use strict";
const GifAsset = {
  extension: Extensions.ExtensionType.Asset,
  detection: {
    test: async () => true,
    add: async (formats) => [...formats, "gif"],
    remove: async (formats) => formats.filter((format) => format !== "gif")
  },
  loader: {
    /** used for deprecation purposes */
    name: "gifLoader",
    id: "gif",
    test: (url) => path.path.extname(url) === ".gif" || url.startsWith("data:image/gif"),
    load: async (url, asset) => {
      const response = await adapter.DOMAdapter.get().fetch(url);
      const buffer = await response.arrayBuffer();
      return GifSource.GifSource.from(buffer, asset?.data);
    },
    unload: async (asset) => {
      asset.destroy();
    }
  }
};

exports.GifAsset = GifAsset;
//# sourceMappingURL=GifAsset.js.map
