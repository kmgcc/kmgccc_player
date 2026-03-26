"use strict";
function cleanHash(hash) {
  let clean = false;
  for (const i in hash) {
    if (hash[i] == void 0) {
      clean = true;
      break;
    }
  }
  if (!clean) return hash;
  const cleanHash2 = /* @__PURE__ */ Object.create(null);
  for (const i in hash) {
    const value = hash[i];
    if (value) {
      cleanHash2[i] = value;
    }
  }
  return cleanHash2;
}
function cleanArray(arr) {
  let offset = 0;
  for (let i = 0; i < arr.length; i++) {
    if (arr[i] == void 0) {
      offset++;
    } else {
      arr[i - offset] = arr[i];
    }
  }
  arr.length -= offset;
  return arr;
}

export { cleanArray, cleanHash };
//# sourceMappingURL=clean.mjs.map
