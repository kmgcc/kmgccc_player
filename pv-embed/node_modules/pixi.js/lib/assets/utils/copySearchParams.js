'use strict';

"use strict";
const copySearchParams = (targetUrl, sourceUrl) => {
  const searchParams = sourceUrl.split("?")[1];
  if (searchParams) {
    targetUrl += `?${searchParams}`;
  }
  return targetUrl;
};

exports.copySearchParams = copySearchParams;
//# sourceMappingURL=copySearchParams.js.map
