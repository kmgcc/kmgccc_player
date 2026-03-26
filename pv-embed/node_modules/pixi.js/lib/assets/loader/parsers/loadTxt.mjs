import { DOMAdapter } from '../../../environment/adapter.mjs';
import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { checkDataUrl } from '../../utils/checkDataUrl.mjs';
import { checkExtension } from '../../utils/checkExtension.mjs';
import { LoaderParserPriority } from './LoaderParser.mjs';

"use strict";
const validTXTExtension = ".txt";
const validTXTMIME = "text/plain";
const loadTxt = {
  /** used for deprecation purposes */
  name: "loadTxt",
  id: "text",
  extension: {
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.Low,
    name: "loadTxt"
  },
  test(url) {
    return checkDataUrl(url, validTXTMIME) || checkExtension(url, validTXTExtension);
  },
  async load(url) {
    const response = await DOMAdapter.get().fetch(url);
    const txt = await response.text();
    return txt;
  }
};

export { loadTxt };
//# sourceMappingURL=loadTxt.mjs.map
