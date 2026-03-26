'use strict';

var adapter = require('../../../environment/adapter.js');
var Extensions = require('../../../extensions/Extensions.js');
var checkDataUrl = require('../../utils/checkDataUrl.js');
var checkExtension = require('../../utils/checkExtension.js');
var LoaderParser = require('./LoaderParser.js');

"use strict";
const validTXTExtension = ".txt";
const validTXTMIME = "text/plain";
const loadTxt = {
  /** used for deprecation purposes */
  name: "loadTxt",
  id: "text",
  extension: {
    type: Extensions.ExtensionType.LoadParser,
    priority: LoaderParser.LoaderParserPriority.Low,
    name: "loadTxt"
  },
  test(url) {
    return checkDataUrl.checkDataUrl(url, validTXTMIME) || checkExtension.checkExtension(url, validTXTExtension);
  },
  async load(url) {
    const response = await adapter.DOMAdapter.get().fetch(url);
    const txt = await response.text();
    return txt;
  }
};

exports.loadTxt = loadTxt;
//# sourceMappingURL=loadTxt.js.map
