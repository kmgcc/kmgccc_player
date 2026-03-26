"use strict";
let unsafeEval;
function unsafeEvalSupported() {
  if (typeof unsafeEval === "boolean") {
    return unsafeEval;
  }
  try {
    const func = new Function("param1", "param2", "param3", "return param1[param2] === param3;");
    unsafeEval = func({ a: "b" }, "a", "b") === true;
  } catch (_e) {
    unsafeEval = false;
  }
  return unsafeEval;
}

export { unsafeEvalSupported };
//# sourceMappingURL=unsafeEvalSupported.mjs.map
