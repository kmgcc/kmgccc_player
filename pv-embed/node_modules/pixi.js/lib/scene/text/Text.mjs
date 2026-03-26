import { TextureSource } from '../../rendering/renderers/shared/texture/sources/TextureSource.mjs';
import { TextureStyle } from '../../rendering/renderers/shared/texture/TextureStyle.mjs';
import { AbstractText, ensureTextOptions } from './AbstractText.mjs';
import { CanvasTextGenerator } from './canvas/CanvasTextGenerator.mjs';
import { CanvasTextMetrics } from './canvas/CanvasTextMetrics.mjs';
import { TextStyle } from './TextStyle.mjs';
import './init.mjs';

"use strict";
class Text extends AbstractText {
  constructor(...args) {
    const options = ensureTextOptions(args, "Text");
    super(options, TextStyle);
    /** @internal */
    this.renderPipeId = "text";
    if (options.textureStyle) {
      this.textureStyle = options.textureStyle instanceof TextureStyle ? options.textureStyle : new TextureStyle(options.textureStyle);
    }
    this.autoGenerateMipmaps = options.autoGenerateMipmaps ?? TextureSource.defaultOptions.autoGenerateMipmaps;
  }
  /** @private */
  updateBounds() {
    const bounds = this._bounds;
    const anchor = this._anchor;
    let width = 0;
    let height = 0;
    if (this._style.trim) {
      const { frame, canvasAndContext } = CanvasTextGenerator.getCanvasAndContext({
        text: this.text,
        style: this._style,
        resolution: 1
      });
      CanvasTextGenerator.returnCanvasAndContext(canvasAndContext);
      width = frame.width;
      height = frame.height;
    } else {
      const canvasMeasurement = CanvasTextMetrics.measureText(
        this._text,
        this._style
      );
      width = canvasMeasurement.width;
      height = canvasMeasurement.height;
    }
    bounds.minX = -anchor._x * width;
    bounds.maxX = bounds.minX + width;
    bounds.minY = -anchor._y * height;
    bounds.maxY = bounds.minY + height;
  }
}

export { Text };
//# sourceMappingURL=Text.mjs.map
