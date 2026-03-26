import { groupD8 } from '../../maths/matrix/groupD8.mjs';
import { Rectangle } from '../../maths/shapes/Rectangle.mjs';
import { Texture } from '../../rendering/renderers/shared/texture/Texture.mjs';
import { AbstractBitmapFont } from './AbstractBitmapFont.mjs';
import { BitmapFontManager } from './BitmapFontManager.mjs';

"use strict";
class BitmapFont extends AbstractBitmapFont {
  constructor(options, url) {
    super();
    const { textures, data } = options;
    Object.keys(data.pages).forEach((key) => {
      const pageData = data.pages[parseInt(key, 10)];
      const texture = textures[pageData.id];
      this.pages.push({ texture });
    });
    Object.keys(data.chars).forEach((key) => {
      const charData = data.chars[key];
      const {
        frame: textureFrame,
        source: textureSource,
        rotate: textureRotate
      } = textures[charData.page];
      const frame = groupD8.transformRectCoords(
        charData,
        textureFrame,
        textureRotate,
        new Rectangle()
      );
      const texture = new Texture({
        frame,
        orig: new Rectangle(0, 0, charData.width, charData.height),
        source: textureSource,
        rotate: textureRotate
      });
      this.chars[key] = {
        id: key.codePointAt(0),
        xOffset: charData.xOffset,
        yOffset: charData.yOffset,
        xAdvance: charData.xAdvance,
        kerning: charData.kerning ?? {},
        texture
      };
    });
    this.baseRenderedFontSize = data.fontSize;
    this.baseMeasurementFontSize = data.fontSize;
    this.fontMetrics = {
      ascent: 0,
      descent: 0,
      fontSize: data.fontSize
    };
    this.baseLineOffset = data.baseLineOffset;
    this.lineHeight = data.lineHeight;
    this.fontFamily = data.fontFamily;
    this.distanceField = data.distanceField ?? {
      type: "none",
      range: 0
    };
    this.url = url;
  }
  /** Destroys the BitmapFont object. */
  destroy() {
    super.destroy();
    for (let i = 0; i < this.pages.length; i++) {
      const { texture } = this.pages[i];
      texture.destroy(true);
    }
    this.pages = null;
  }
  /**
   * Generates and installs a bitmap font with the specified options.
   * The font will be cached and available for use in BitmapText objects.
   * @param options - Setup options for font generation
   * @returns Installed font instance
   * @example
   * ```ts
   * // Install a basic font
   * BitmapFont.install({
   *     name: 'Title',
   *     style: {
   *         fontFamily: 'Arial',
   *         fontSize: 32,
   *         fill: '#ffffff'
   *     }
   * });
   *
   * // Install with advanced options
   * BitmapFont.install({
   *     name: 'Custom',
   *     style: {
   *         fontFamily: 'Arial',
   *         fontSize: 24,
   *         fill: '#00ff00',
   *         stroke: { color: '#000000', width: 2 }
   *     },
   *     chars: [['a', 'z'], ['A', 'Z'], ['0', '9']],
   *     resolution: 2,
   *     padding: 4,
   *     textureStyle: {
   *         scaleMode: 'nearest'
   *     }
   * });
   * ```
   */
  static install(options) {
    BitmapFontManager.install(options);
  }
  /**
   * Uninstalls a bitmap font from the cache.
   * This frees up memory and resources associated with the font.
   * @param name - The name of the bitmap font to uninstall
   * @example
   * ```ts
   * // Remove a font when it's no longer needed
   * BitmapFont.uninstall('MyCustomFont');
   *
   * // Clear multiple fonts
   * ['Title', 'Heading', 'Body'].forEach(BitmapFont.uninstall);
   * ```
   */
  static uninstall(name) {
    BitmapFontManager.uninstall(name);
  }
}

export { BitmapFont };
//# sourceMappingURL=BitmapFont.mjs.map
