import { DOMAdapter } from '../../environment/adapter.mjs';

"use strict";
function isSafari() {
  const { userAgent } = DOMAdapter.get().getNavigator();
  return /^((?!chrome|android).)*safari/i.test(userAgent);
}

export { isSafari };
//# sourceMappingURL=isSafari.mjs.map
