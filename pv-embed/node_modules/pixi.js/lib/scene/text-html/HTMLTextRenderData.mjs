import { DOMAdapter } from '../../environment/adapter.mjs';

"use strict";
const nssvg = "http://www.w3.org/2000/svg";
const nsxhtml = "http://www.w3.org/1999/xhtml";
class HTMLTextRenderData {
  constructor() {
    this.svgRoot = document.createElementNS(nssvg, "svg");
    this.foreignObject = document.createElementNS(nssvg, "foreignObject");
    this.domElement = document.createElementNS(nsxhtml, "div");
    this.styleElement = document.createElementNS(nsxhtml, "style");
    const { foreignObject, svgRoot, styleElement, domElement } = this;
    foreignObject.setAttribute("width", "10000");
    foreignObject.setAttribute("height", "10000");
    foreignObject.style.overflow = "hidden";
    svgRoot.appendChild(foreignObject);
    foreignObject.appendChild(styleElement);
    foreignObject.appendChild(domElement);
    this.image = DOMAdapter.get().createImage();
  }
  destroy() {
    this.svgRoot.remove();
    this.foreignObject.remove();
    this.styleElement.remove();
    this.domElement.remove();
    this.image.src = "";
    this.image.remove();
    this.svgRoot = null;
    this.foreignObject = null;
    this.styleElement = null;
    this.domElement = null;
    this.image = null;
    this.canvasAndContext = null;
  }
}

export { HTMLTextRenderData };
//# sourceMappingURL=HTMLTextRenderData.mjs.map
