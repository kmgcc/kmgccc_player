"use strict";
const copySearchParams = (targetUrl, sourceUrl) => {
  const searchParams = sourceUrl.split("?")[1];
  if (searchParams) {
    targetUrl += `?${searchParams}`;
  }
  return targetUrl;
};

export { copySearchParams };
//# sourceMappingURL=copySearchParams.mjs.map
