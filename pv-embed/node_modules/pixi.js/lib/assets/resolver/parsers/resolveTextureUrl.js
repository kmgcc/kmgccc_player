'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var loadTextures = require('../../loader/parsers/textures/loadTextures.js');
var Resolver = require('../Resolver.js');

"use strict";
const resolveTextureUrl = {
  extension: {
    type: Extensions.ExtensionType.ResolveParser,
    name: "resolveTexture"
  },
  test: loadTextures.loadTextures.test,
  parse: (value) => ({
    resolution: parseFloat(Resolver.Resolver.RETINA_PREFIX.exec(value)?.[1] ?? "1"),
    format: value.split(".").pop(),
    src: value
  })
};

exports.resolveTextureUrl = resolveTextureUrl;
//# sourceMappingURL=resolveTextureUrl.js.map
