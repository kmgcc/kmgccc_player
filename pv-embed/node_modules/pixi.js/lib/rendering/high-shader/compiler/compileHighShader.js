'use strict';

var addBits = require('./utils/addBits.js');
var compileHooks = require('./utils/compileHooks.js');
var compileInputs = require('./utils/compileInputs.js');
var compileOutputs = require('./utils/compileOutputs.js');
var injectBits = require('./utils/injectBits.js');

"use strict";
const cacheMap = /* @__PURE__ */ Object.create(null);
const bitCacheMap = /* @__PURE__ */ new Map();
let CACHE_UID = 0;
function compileHighShader({
  template,
  bits
}) {
  const cacheId = generateCacheId(template, bits);
  if (cacheMap[cacheId]) return cacheMap[cacheId];
  const { vertex, fragment } = compileInputsAndOutputs(template, bits);
  cacheMap[cacheId] = compileBits(vertex, fragment, bits);
  return cacheMap[cacheId];
}
function compileHighShaderGl({
  template,
  bits
}) {
  const cacheId = generateCacheId(template, bits);
  if (cacheMap[cacheId]) return cacheMap[cacheId];
  cacheMap[cacheId] = compileBits(template.vertex, template.fragment, bits);
  return cacheMap[cacheId];
}
function compileInputsAndOutputs(template, bits) {
  const vertexFragments = bits.map((shaderBit) => shaderBit.vertex).filter((v) => !!v);
  const fragmentFragments = bits.map((shaderBit) => shaderBit.fragment).filter((v) => !!v);
  let compiledVertex = compileInputs.compileInputs(vertexFragments, template.vertex, true);
  compiledVertex = compileOutputs.compileOutputs(vertexFragments, compiledVertex);
  const compiledFragment = compileInputs.compileInputs(fragmentFragments, template.fragment, true);
  return {
    vertex: compiledVertex,
    fragment: compiledFragment
  };
}
function generateCacheId(template, bits) {
  return bits.map((highFragment) => {
    if (!bitCacheMap.has(highFragment)) {
      bitCacheMap.set(highFragment, CACHE_UID++);
    }
    return bitCacheMap.get(highFragment);
  }).sort((a, b) => a - b).join("-") + template.vertex + template.fragment;
}
function compileBits(vertex, fragment, bits) {
  const vertexParts = compileHooks.compileHooks(vertex);
  const fragmentParts = compileHooks.compileHooks(fragment);
  bits.forEach((shaderBit) => {
    addBits.addBits(shaderBit.vertex, vertexParts, shaderBit.name);
    addBits.addBits(shaderBit.fragment, fragmentParts, shaderBit.name);
  });
  return {
    vertex: injectBits.injectBits(vertex, vertexParts),
    fragment: injectBits.injectBits(fragment, fragmentParts)
  };
}

exports.compileHighShader = compileHighShader;
exports.compileHighShaderGl = compileHighShaderGl;
//# sourceMappingURL=compileHighShader.js.map
