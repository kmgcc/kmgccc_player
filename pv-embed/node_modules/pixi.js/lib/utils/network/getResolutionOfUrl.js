'use strict';

var Resolver = require('../../assets/resolver/Resolver.js');

"use strict";
function getResolutionOfUrl(url, defaultValue = 1) {
  const resolution = Resolver.Resolver.RETINA_PREFIX?.exec(url);
  if (resolution) {
    return parseFloat(resolution[1]);
  }
  return defaultValue;
}

exports.getResolutionOfUrl = getResolutionOfUrl;
//# sourceMappingURL=getResolutionOfUrl.js.map
