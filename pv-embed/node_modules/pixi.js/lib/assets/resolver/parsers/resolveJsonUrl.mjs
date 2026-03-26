import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Resolver } from '../Resolver.mjs';
import { resolveTextureUrl } from './resolveTextureUrl.mjs';

"use strict";
const resolveJsonUrl = {
  extension: {
    type: ExtensionType.ResolveParser,
    priority: -2,
    name: "resolveJson"
  },
  test: (value) => Resolver.RETINA_PREFIX.test(value) && value.endsWith(".json"),
  parse: resolveTextureUrl.parse
};

export { resolveJsonUrl };
//# sourceMappingURL=resolveJsonUrl.mjs.map
