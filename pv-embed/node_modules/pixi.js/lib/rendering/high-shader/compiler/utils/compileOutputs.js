'use strict';

"use strict";
function extractOutputs(fragmentSource, out) {
  let match;
  const regex = /@out\s+([^;]+);/g;
  while ((match = regex.exec(fragmentSource)) !== null) {
    out.push(match[1]);
  }
}
function extractVariableName(value) {
  const regex = /\b(\w+)\s*:/g;
  const match = regex.exec(value);
  return match ? match[1] : "";
}
function stripVariable(value) {
  const regex = /@.*?\s+/g;
  return value.replace(regex, "");
}
function compileOutputs(fragments, template) {
  const results = [];
  extractOutputs(template, results);
  fragments.forEach((fragment) => {
    if (fragment.header) {
      extractOutputs(fragment.header, results);
    }
  });
  let index = 0;
  const mainStruct = results.sort().map((inValue) => {
    if (inValue.indexOf("builtin") > -1) {
      return inValue;
    }
    return `@location(${index++}) ${inValue}`;
  }).join(",\n");
  const mainStart = results.sort().map((inValue) => `       var ${stripVariable(inValue)};`).join("\n");
  const mainEnd = `return VSOutput(
            ${results.sort().map((inValue) => ` ${extractVariableName(inValue)}`).join(",\n")});`;
  let compiledCode = template.replace(/@out\s+[^;]+;\s*/g, "");
  compiledCode = compiledCode.replace("{{struct}}", `
${mainStruct}
`);
  compiledCode = compiledCode.replace("{{start}}", `
${mainStart}
`);
  compiledCode = compiledCode.replace("{{return}}", `
${mainEnd}
`);
  return compiledCode;
}

exports.compileOutputs = compileOutputs;
//# sourceMappingURL=compileOutputs.js.map
