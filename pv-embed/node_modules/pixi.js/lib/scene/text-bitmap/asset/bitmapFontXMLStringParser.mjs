import { DOMAdapter } from '../../../environment/adapter.mjs';
import { bitmapFontXMLParser } from './bitmapFontXMLParser.mjs';

"use strict";
const bitmapFontXMLStringParser = {
  test(data) {
    if (typeof data === "string" && data.match(/<font(\s|>)/)) {
      return bitmapFontXMLParser.test(DOMAdapter.get().parseXML(data));
    }
    return false;
  },
  parse(data) {
    return bitmapFontXMLParser.parse(DOMAdapter.get().parseXML(data));
  }
};

export { bitmapFontXMLStringParser };
//# sourceMappingURL=bitmapFontXMLStringParser.mjs.map
