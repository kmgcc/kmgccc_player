'use strict';

var Resolver = require('../../assets/resolver/Resolver.js');
var checkExtension = require('../../assets/utils/checkExtension.js');
var Extensions = require('../../extensions/Extensions.js');

"use strict";
const validFormats = ["basis", "bc7", "bc6h", "astc", "etc2", "bc5", "bc4", "bc3", "bc2", "bc1", "eac"];
const resolveCompressedTextureUrl = {
  extension: Extensions.ExtensionType.ResolveParser,
  test: (value) => checkExtension.checkExtension(value, [".ktx", ".ktx2", ".dds"]),
  parse: (value) => {
    let format;
    const splitValue = value.split(".");
    if (splitValue.length > 2) {
      const newFormat = splitValue[splitValue.length - 2];
      if (validFormats.includes(newFormat)) {
        format = newFormat;
      }
    } else {
      format = splitValue[splitValue.length - 1];
    }
    return {
      resolution: parseFloat(Resolver.Resolver.RETINA_PREFIX.exec(value)?.[1] ?? "1"),
      format,
      src: value
    };
  }
};

exports.resolveCompressedTextureUrl = resolveCompressedTextureUrl;
exports.validFormats = validFormats;
//# sourceMappingURL=resolveCompressedTextureUrl.js.map
