import isMobileJs from 'ismobilejs';

"use strict";
const isMobileCall = isMobileJs.default ?? isMobileJs;
const isMobile = isMobileCall(globalThis.navigator);

export { isMobile };
//# sourceMappingURL=isMobile.mjs.map
