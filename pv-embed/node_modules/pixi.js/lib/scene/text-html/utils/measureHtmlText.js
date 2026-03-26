'use strict';

var HTMLTextRenderData = require('../HTMLTextRenderData.js');

"use strict";
let tempHTMLTextRenderData;
function measureHtmlText(text, style, fontStyleCSS, htmlTextRenderData) {
  htmlTextRenderData || (htmlTextRenderData = tempHTMLTextRenderData || (tempHTMLTextRenderData = new HTMLTextRenderData.HTMLTextRenderData()));
  const { domElement, styleElement, svgRoot } = htmlTextRenderData;
  domElement.innerHTML = `<style>${style.cssStyle};</style><div style='padding:0'>${text}</div>`;
  domElement.setAttribute("style", "transform-origin: top left; display: inline-block");
  if (fontStyleCSS) {
    styleElement.textContent = fontStyleCSS;
  }
  document.body.appendChild(svgRoot);
  let contentWidth = domElement.scrollWidth;
  let contentHeight = domElement.scrollHeight;
  svgRoot.remove();
  if (style.dropShadow) {
    const { distance, angle, blur } = style.dropShadow;
    const shadowOffsetX = Math.abs(Math.round(Math.cos(angle) * distance));
    const shadowOffsetY = Math.abs(Math.round(Math.sin(angle) * distance));
    contentWidth += shadowOffsetX + blur;
    contentHeight += shadowOffsetY + blur;
  }
  const doublePadding = style.padding * 2;
  return {
    width: contentWidth - doublePadding,
    height: contentHeight - doublePadding
  };
}

exports.measureHtmlText = measureHtmlText;
//# sourceMappingURL=measureHtmlText.js.map
