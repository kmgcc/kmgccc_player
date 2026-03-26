import { deprecation } from '../../../utils/logging/deprecation.mjs';

"use strict";
function getFastGlobalBounds(target, bounds) {
  deprecation("8.7.0", "Use container.getFastGlobalBounds() instead");
  return target.getFastGlobalBounds(true, bounds);
}

export { getFastGlobalBounds };
//# sourceMappingURL=getFastGlobalBounds.mjs.map
