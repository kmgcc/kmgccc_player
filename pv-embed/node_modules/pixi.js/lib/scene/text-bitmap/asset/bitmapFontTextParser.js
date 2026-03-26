'use strict';

"use strict";
const bitmapFontTextParser = {
  test(data) {
    return typeof data === "string" && data.startsWith("info face=");
  },
  parse(txt) {
    const items = txt.match(/^[a-z]+\s+.+$/gm);
    const rawData = {
      info: [],
      common: [],
      page: [],
      char: [],
      chars: [],
      kerning: [],
      kernings: [],
      distanceField: []
    };
    for (const i in items) {
      const name = items[i].match(/^[a-z]+/gm)[0];
      const attributeList = items[i].match(/[a-zA-Z]+=([^\s"']+|"([^"]*)")/gm);
      const itemData = {};
      for (const i2 in attributeList) {
        const split = attributeList[i2].split("=");
        const key = split[0];
        const strValue = split[1].replace(/"/gm, "");
        const floatValue = parseFloat(strValue);
        const value = isNaN(floatValue) ? strValue : floatValue;
        itemData[key] = value;
      }
      rawData[name].push(itemData);
    }
    const font = {
      chars: {},
      pages: [],
      lineHeight: 0,
      fontSize: 0,
      fontFamily: "",
      distanceField: null,
      baseLineOffset: 0
    };
    const [info] = rawData.info;
    const [common] = rawData.common;
    const [distanceField] = rawData.distanceField ?? [];
    if (distanceField) {
      font.distanceField = {
        range: parseInt(distanceField.distanceRange, 10),
        type: distanceField.fieldType
      };
    }
    font.fontSize = parseInt(info.size, 10);
    font.fontFamily = info.face;
    font.lineHeight = parseInt(common.lineHeight, 10);
    const page = rawData.page;
    for (let i = 0; i < page.length; i++) {
      font.pages.push({
        id: parseInt(page[i].id, 10) || 0,
        file: page[i].file
      });
    }
    const map = {};
    font.baseLineOffset = font.lineHeight - parseInt(common.base, 10);
    const char = rawData.char;
    for (let i = 0; i < char.length; i++) {
      const charNode = char[i];
      const id = parseInt(charNode.id, 10);
      let letter = charNode.letter ?? charNode.char ?? String.fromCharCode(id);
      if (letter === "space") letter = " ";
      map[id] = letter;
      font.chars[letter] = {
        id,
        // texture deets..
        page: parseInt(charNode.page, 10) || 0,
        x: parseInt(charNode.x, 10),
        y: parseInt(charNode.y, 10),
        width: parseInt(charNode.width, 10),
        height: parseInt(charNode.height, 10),
        xOffset: parseInt(charNode.xoffset, 10),
        yOffset: parseInt(charNode.yoffset, 10),
        xAdvance: parseInt(charNode.xadvance, 10),
        kerning: {}
      };
    }
    const kerning = rawData.kerning || [];
    for (let i = 0; i < kerning.length; i++) {
      const first = parseInt(kerning[i].first, 10);
      const second = parseInt(kerning[i].second, 10);
      const amount = parseInt(kerning[i].amount, 10);
      if (font.chars[map[second]]) font.chars[map[second]].kerning[map[first]] = amount;
    }
    return font;
  }
};

exports.bitmapFontTextParser = bitmapFontTextParser;
//# sourceMappingURL=bitmapFontTextParser.js.map
