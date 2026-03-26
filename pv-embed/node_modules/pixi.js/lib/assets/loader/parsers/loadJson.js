'use strict';

var adapter = require('../../../environment/adapter.js');
var Extensions = require('../../../extensions/Extensions.js');
var checkDataUrl = require('../../utils/checkDataUrl.js');
var checkExtension = require('../../utils/checkExtension.js');
var LoaderParser = require('./LoaderParser.js');

"use strict";
const validJSONExtension = ".json";
const validJSONMIME = "application/json";
const loadJson = {
  extension: {
    type: Extensions.ExtensionType.LoadParser,
    priority: LoaderParser.LoaderParserPriority.Low
  },
  /** used for deprecation purposes */
  name: "loadJson",
  id: "json",
  test(url) {
    return checkDataUrl.checkDataUrl(url, validJSONMIME) || checkExtension.checkExtension(url, validJSONExtension);
  },
  async load(url) {
    const response = await adapter.DOMAdapter.get().fetch(url);
    const json = await response.json();
    return json;
  }
};

exports.loadJson = loadJson;
//# sourceMappingURL=loadJson.js.map
