import { ExtensionType } from '../../extensions/Extensions.mjs';
import { CanvasPool } from '../../rendering/renderers/shared/texture/CanvasPool.mjs';
import { TexturePool } from '../../rendering/renderers/shared/texture/TexturePool.mjs';
import { RendererType } from '../../rendering/renderers/types.mjs';
import { isSafari } from '../../utils/browser/isSafari.mjs';
import { warn } from '../../utils/logging/warn.mjs';
import { BigPool } from '../../utils/pool/PoolGroup.mjs';
import { getPo2TextureFromSource } from '../text/utils/getPo2TextureFromSource.mjs';
import { HTMLTextRenderData } from './HTMLTextRenderData.mjs';
import { extractFontFamilies } from './utils/extractFontFamilies.mjs';
import { getFontCss } from './utils/getFontCss.mjs';
import { getSVGUrl } from './utils/getSVGUrl.mjs';
import { getTemporaryCanvasFromImage } from './utils/getTemporaryCanvasFromImage.mjs';
import { loadSVGImage } from './utils/loadSVGImage.mjs';
import { measureHtmlText } from './utils/measureHtmlText.mjs';

"use strict";
class HTMLTextSystem {
  constructor(renderer) {
    this._activeTextures = {};
    this._renderer = renderer;
    this._createCanvas = renderer.type === RendererType.WEBGPU;
  }
  /**
   * @param options
   * @deprecated Use getTexturePromise instead
   */
  getTexture(options) {
    return this.getTexturePromise(options);
  }
  /**
   * Increases the reference count for a texture.
   * @param text - The HTMLText instance associated with the texture.
   */
  getManagedTexture(text) {
    const textKey = text.styleKey;
    if (this._activeTextures[textKey]) {
      this._increaseReferenceCount(textKey);
      return this._activeTextures[textKey].promise;
    }
    const promise = this._buildTexturePromise(text).then((texture) => {
      this._activeTextures[textKey].texture = texture;
      return texture;
    });
    this._activeTextures[textKey] = {
      texture: null,
      promise,
      usageCount: 1
    };
    return promise;
  }
  /**
   * Gets the current reference count for a texture associated with a text key.
   * @param textKey - The unique key identifying the text style configuration
   * @returns The number of Text instances currently using this texture
   */
  getReferenceCount(textKey) {
    return this._activeTextures[textKey]?.usageCount ?? null;
  }
  _increaseReferenceCount(textKey) {
    this._activeTextures[textKey].usageCount++;
  }
  /**
   * Decreases the reference count for a texture.
   * If the count reaches zero, the texture is cleaned up.
   * @param textKey - The key associated with the HTMLText instance.
   */
  decreaseReferenceCount(textKey) {
    const activeTexture = this._activeTextures[textKey];
    if (!activeTexture) return;
    activeTexture.usageCount--;
    if (activeTexture.usageCount === 0) {
      if (activeTexture.texture) {
        this._cleanUp(activeTexture.texture);
      } else {
        activeTexture.promise.then((texture) => {
          activeTexture.texture = texture;
          this._cleanUp(activeTexture.texture);
        }).catch(() => {
          warn("HTMLTextSystem: Failed to clean texture");
        });
      }
      this._activeTextures[textKey] = null;
    }
  }
  /**
   * Returns a promise that resolves to a texture for the given HTMLText options.
   * @param options - The options for the HTMLText.
   * @returns A promise that resolves to a Texture.
   */
  getTexturePromise(options) {
    return this._buildTexturePromise(options);
  }
  async _buildTexturePromise(options) {
    const { text, style, resolution, textureStyle, autoGenerateMipmaps } = options;
    const htmlTextData = BigPool.get(HTMLTextRenderData);
    const fontFamilies = extractFontFamilies(text, style);
    const fontCSS = await getFontCss(fontFamilies);
    const measured = measureHtmlText(text, style, fontCSS, htmlTextData);
    const width = Math.ceil(Math.ceil(Math.max(1, measured.width) + style.padding * 2) * resolution);
    const height = Math.ceil(Math.ceil(Math.max(1, measured.height) + style.padding * 2) * resolution);
    const image = htmlTextData.image;
    const uvSafeOffset = 2;
    image.width = (width | 0) + uvSafeOffset;
    image.height = (height | 0) + uvSafeOffset;
    const svgURL = getSVGUrl(text, style, resolution, fontCSS, htmlTextData);
    await loadSVGImage(image, svgURL, isSafari() && fontFamilies.length > 0);
    const resource = image;
    let canvasAndContext;
    if (this._createCanvas) {
      canvasAndContext = getTemporaryCanvasFromImage(image, resolution);
    }
    const texture = getPo2TextureFromSource(
      canvasAndContext ? canvasAndContext.canvas : resource,
      image.width - uvSafeOffset,
      image.height - uvSafeOffset,
      resolution,
      autoGenerateMipmaps
    );
    if (textureStyle) texture.source.style = textureStyle;
    if (this._createCanvas) {
      this._renderer.texture.initSource(texture.source);
      CanvasPool.returnCanvasAndContext(canvasAndContext);
    }
    BigPool.return(htmlTextData);
    return texture;
  }
  returnTexturePromise(texturePromise) {
    texturePromise.then((texture) => {
      this._cleanUp(texture);
    }).catch(() => {
      warn("HTMLTextSystem: Failed to clean texture");
    });
  }
  _cleanUp(texture) {
    TexturePool.returnTexture(texture, true);
    texture.source.resource = null;
    texture.source.uploadMethodId = "unknown";
  }
  destroy() {
    this._renderer = null;
    for (const key in this._activeTextures) {
      if (this._activeTextures[key]) this.returnTexturePromise(this._activeTextures[key].promise);
    }
    this._activeTextures = null;
  }
}
/** @ignore */
HTMLTextSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem,
    ExtensionType.CanvasSystem
  ],
  name: "htmlText"
};

export { HTMLTextSystem };
//# sourceMappingURL=HTMLTextSystem.mjs.map
