import { DOMAdapter } from '../../../environment/adapter.mjs';
import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { checkDataUrl } from '../../utils/checkDataUrl.mjs';
import { checkExtension } from '../../utils/checkExtension.mjs';
import { LoaderParserPriority } from './LoaderParser.mjs';

"use strict";
const validJSONExtension = ".json";
const validJSONMIME = "application/json";
const loadJson = {
  extension: {
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.Low
  },
  /** used for deprecation purposes */
  name: "loadJson",
  id: "json",
  test(url) {
    return checkDataUrl(url, validJSONMIME) || checkExtension(url, validJSONExtension);
  },
  async load(url) {
    const response = await DOMAdapter.get().fetch(url);
    const json = await response.json();
    return json;
  }
};

export { loadJson };
//# sourceMappingURL=loadJson.mjs.map
