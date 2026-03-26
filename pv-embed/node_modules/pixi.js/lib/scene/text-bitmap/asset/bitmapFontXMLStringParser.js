'use strict';

var adapter = require('../../../environment/adapter.js');
var bitmapFontXMLParser = require('./bitmapFontXMLParser.js');

"use strict";
const bitmapFontXMLStringParser = {
  test(data) {
    if (typeof data === "string" && data.match(/<font(\s|>)/)) {
      return bitmapFontXMLParser.bitmapFontXMLParser.test(adapter.DOMAdapter.get().parseXML(data));
    }
    return false;
  },
  parse(data) {
    return bitmapFontXMLParser.bitmapFontXMLParser.parse(adapter.DOMAdapter.get().parseXML(data));
  }
};

exports.bitmapFontXMLStringParser = bitmapFontXMLStringParser;
//# sourceMappingURL=bitmapFontXMLStringParser.js.map
