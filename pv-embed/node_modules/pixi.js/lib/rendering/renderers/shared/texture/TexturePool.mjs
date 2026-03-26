import { nextPow2 } from '../../../../maths/misc/pow2.mjs';
import { GlobalResourceRegistry } from '../../../../utils/pool/GlobalResourceRegistry.mjs';
import { TextureSource } from './sources/TextureSource.mjs';
import { Texture } from './Texture.mjs';
import { TextureStyle } from './TextureStyle.mjs';

"use strict";
let count = 0;
class TexturePoolClass {
  /**
   * @param textureOptions - options that will be passed to BaseRenderTexture constructor
   * @param {SCALE_MODE} [textureOptions.scaleMode] - See {@link SCALE_MODE} for possible values.
   */
  constructor(textureOptions) {
    this._poolKeyHash = /* @__PURE__ */ Object.create(null);
    this._texturePool = {};
    this.textureOptions = textureOptions || {};
    this.enableFullScreen = false;
    this.textureStyle = new TextureStyle(this.textureOptions);
  }
  /**
   * Creates texture with params that were specified in pool constructor.
   * @param pixelWidth - Width of texture in pixels.
   * @param pixelHeight - Height of texture in pixels.
   * @param antialias
   * @param autoGenerateMipmaps - Whether to automatically generate mipmaps for this texture
   */
  createTexture(pixelWidth, pixelHeight, antialias, autoGenerateMipmaps) {
    const textureSource = new TextureSource({
      ...this.textureOptions,
      width: pixelWidth,
      height: pixelHeight,
      resolution: 1,
      antialias,
      autoGarbageCollect: false,
      autoGenerateMipmaps
    });
    return new Texture({
      source: textureSource,
      label: `texturePool_${count++}`
    });
  }
  /**
   * Gets a Power-of-Two render texture or fullScreen texture
   * @param frameWidth - The minimum width of the render texture.
   * @param frameHeight - The minimum height of the render texture.
   * @param resolution - The resolution of the render texture.
   * @param antialias
   * @param autoGenerateMipmaps - Whether to automatically generate mipmaps. Defaults to false.
   * @returns The new render texture.
   */
  getOptimalTexture(frameWidth, frameHeight, resolution = 1, antialias, autoGenerateMipmaps = false) {
    let po2Width = Math.ceil(frameWidth * resolution - 1e-6);
    let po2Height = Math.ceil(frameHeight * resolution - 1e-6);
    po2Width = nextPow2(po2Width);
    po2Height = nextPow2(po2Height);
    const antialiasFlag = antialias ? 1 : 0;
    const mipmapFlag = autoGenerateMipmaps ? 1 : 0;
    const key = (po2Width << 17) + (po2Height << 2) + (mipmapFlag << 1) + antialiasFlag;
    if (!this._texturePool[key]) {
      this._texturePool[key] = [];
    }
    let texture = this._texturePool[key].pop();
    if (!texture) {
      texture = this.createTexture(po2Width, po2Height, antialias, autoGenerateMipmaps);
    }
    texture.source._resolution = resolution;
    texture.source.width = po2Width / resolution;
    texture.source.height = po2Height / resolution;
    texture.source.pixelWidth = po2Width;
    texture.source.pixelHeight = po2Height;
    texture.frame.x = 0;
    texture.frame.y = 0;
    texture.frame.width = frameWidth;
    texture.frame.height = frameHeight;
    texture.updateUvs();
    this._poolKeyHash[texture.uid] = key;
    return texture;
  }
  /**
   * Gets a pooled texture matching the dimensions and resolution of the given texture.
   *
   * This is a convenience wrapper around {@link TexturePoolClass#getOptimalTexture|getOptimalTexture}
   * that copies width, height, and resolution from an existing texture. Useful when a filter needs
   * a temporary texture the same size as its input (e.g., for multi-pass blur).
   * @param texture - The texture whose dimensions to match.
   * @param antialias - Whether to use antialias on the pooled texture. Defaults to `false`.
   * @returns A pooled texture with power-of-two backing dimensions at the source resolution.
   */
  getSameSizeTexture(texture, antialias = false) {
    const source = texture.source;
    return this.getOptimalTexture(texture.width, texture.height, source._resolution, antialias);
  }
  /**
   * Returns a texture to the pool so it can be reused by future
   * {@link TexturePoolClass#getOptimalTexture|getOptimalTexture}
   * or {@link TexturePoolClass#getSameSizeTexture|getSameSizeTexture} calls.
   *
   * If you modified the texture's style after obtaining it (e.g., changed filtering or wrapping),
   * pass `resetStyle = true` to restore the pool's default {@link TexturePoolClass#textureStyle|textureStyle}.
   * This prevents style changes from leaking into subsequent consumers of the same pooled texture.
   * @param renderTexture - The texture to return to the pool.
   * @param resetStyle - When `true`, replaces the texture source's style with the pool default. Defaults to `false`.
   */
  returnTexture(renderTexture, resetStyle = false) {
    const key = this._poolKeyHash[renderTexture.uid];
    if (resetStyle) {
      renderTexture.source.style = this.textureStyle;
    }
    this._texturePool[key].push(renderTexture);
  }
  /**
   * Clears the pool.
   * @param destroyTextures - Destroy all stored textures.
   */
  clear(destroyTextures) {
    destroyTextures = destroyTextures !== false;
    if (destroyTextures) {
      for (const i in this._texturePool) {
        const textures = this._texturePool[i];
        if (textures) {
          for (let j = 0; j < textures.length; j++) {
            textures[j].destroy(true);
          }
        }
      }
    }
    this._texturePool = {};
  }
}
const TexturePool = new TexturePoolClass();
GlobalResourceRegistry.register(TexturePool);

export { TexturePool, TexturePoolClass };
//# sourceMappingURL=TexturePool.mjs.map
