import { Resolver } from '../../assets/resolver/Resolver.mjs';

"use strict";
function getResolutionOfUrl(url, defaultValue = 1) {
  const resolution = Resolver.RETINA_PREFIX?.exec(url);
  if (resolution) {
    return parseFloat(resolution[1]);
  }
  return defaultValue;
}

export { getResolutionOfUrl };
//# sourceMappingURL=getResolutionOfUrl.mjs.map
