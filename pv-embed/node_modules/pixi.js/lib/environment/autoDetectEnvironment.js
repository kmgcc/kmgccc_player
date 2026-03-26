'use strict';

var Extensions = require('../extensions/Extensions.js');

"use strict";
const environments = [];
Extensions.extensions.handleByNamedList(Extensions.ExtensionType.Environment, environments);
async function loadEnvironmentExtensions(skip) {
  if (skip) return;
  for (let i = 0; i < environments.length; i++) {
    const env = environments[i];
    if (env.value.test()) {
      await env.value.load();
      return;
    }
  }
}
async function autoDetectEnvironment(add) {
  return loadEnvironmentExtensions(!add);
}

exports.autoDetectEnvironment = autoDetectEnvironment;
exports.loadEnvironmentExtensions = loadEnvironmentExtensions;
//# sourceMappingURL=autoDetectEnvironment.js.map
