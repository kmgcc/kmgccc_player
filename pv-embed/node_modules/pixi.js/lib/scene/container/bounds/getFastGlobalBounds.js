'use strict';

var deprecation = require('../../../utils/logging/deprecation.js');

"use strict";
function getFastGlobalBounds(target, bounds) {
  deprecation.deprecation("8.7.0", "Use container.getFastGlobalBounds() instead");
  return target.getFastGlobalBounds(true, bounds);
}

exports.getFastGlobalBounds = getFastGlobalBounds;
//# sourceMappingURL=getFastGlobalBounds.js.map
