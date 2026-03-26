import { extensions, ExtensionType } from '../extensions/Extensions.mjs';

"use strict";
const environments = [];
extensions.handleByNamedList(ExtensionType.Environment, environments);
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

export { autoDetectEnvironment, loadEnvironmentExtensions };
//# sourceMappingURL=autoDetectEnvironment.mjs.map
