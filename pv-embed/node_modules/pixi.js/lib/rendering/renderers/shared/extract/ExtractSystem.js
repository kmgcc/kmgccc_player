'use strict';

var adapter = require('../../../../environment/adapter.js');
var Extensions = require('../../../../extensions/Extensions.js');
var Container = require('../../../../scene/container/Container.js');
var Texture = require('../texture/Texture.js');

"use strict";
const imageTypes = {
  png: "image/png",
  jpg: "image/jpeg",
  webp: "image/webp"
};
const _ExtractSystem = class _ExtractSystem {
  /** @param renderer - The renderer this System works for. */
  constructor(renderer) {
    this._renderer = renderer;
  }
  _normalizeOptions(options, defaults = {}) {
    if (options instanceof Container.Container || options instanceof Texture.Texture) {
      return {
        target: options,
        ...defaults
      };
    }
    return {
      ...defaults,
      ...options
    };
  }
  /**
   * Creates an IImage from a display object or texture.
   * @param options - Options for creating the image, or the target to extract
   * @returns Promise that resolves with the generated IImage
   * @example
   * ```ts
   * // Basic usage with a sprite
   * const sprite = new Sprite(texture);
   * const image = await renderer.extract.image(sprite);
   * document.body.appendChild(image);
   *
   * // Advanced usage with options
   * const image = await renderer.extract.image({
   *     target: container,
   *     format: 'webp',
   *     quality: 0.8,
   *     frame: new Rectangle(0, 0, 100, 100),
   *     resolution: 2,
   *     clearColor: '#ff0000',
   *     antialias: true
   * });
   *
   * // Extract directly from a texture
   * const texture = Texture.from('myTexture.png');
   * const image = await renderer.extract.image(texture);
   * ```
   * @see {@link ExtractImageOptions} For detailed options
   * @see {@link ExtractSystem.base64} For base64 string output
   * @see {@link ExtractSystem.canvas} For canvas output
   * @see {@link ImageLike} For the image interface
   * @category rendering
   */
  async image(options) {
    const image = adapter.DOMAdapter.get().createImage();
    image.src = await this.base64(options);
    return image;
  }
  /**
   * Converts the target into a base64 encoded string.
   *
   * This method works by first creating
   * a canvas using `Extract.canvas` and then converting it to a base64 string.
   * @param options - The options for creating the base64 string, or the target to extract
   * @returns Promise that resolves with the base64 encoded string
   * @example
   * ```ts
   * // Basic usage with a sprite
   * const sprite = new Sprite(texture);
   * const base64 = await renderer.extract.base64(sprite);
   * console.log(base64); // data:image/png;base64,...
   *
   * // Advanced usage with options
   * const base64 = await renderer.extract.base64({
   *     target: container,
   *     format: 'webp',
   *     quality: 0.8,
   *     frame: new Rectangle(0, 0, 100, 100),
   *     resolution: 2
   * });
   * ```
   * @throws Will throw an error if the platform doesn't support any of:
   * - ICanvas.toDataURL
   * - ICanvas.toBlob
   * - ICanvas.convertToBlob
   * @see {@link ExtractImageOptions} For detailed options
   * @see {@link ExtractSystem.canvas} For canvas output
   * @see {@link ExtractSystem.image} For HTMLImage output
   * @category rendering
   */
  async base64(options) {
    options = this._normalizeOptions(
      options,
      _ExtractSystem.defaultImageOptions
    );
    const { format, quality } = options;
    const canvas = this.canvas(options);
    if (canvas.toBlob !== void 0) {
      return new Promise((resolve, reject) => {
        canvas.toBlob((blob) => {
          if (!blob) {
            reject(new Error("ICanvas.toBlob failed!"));
            return;
          }
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = reject;
          reader.readAsDataURL(blob);
        }, imageTypes[format], quality);
      });
    }
    if (canvas.toDataURL !== void 0) {
      return canvas.toDataURL(imageTypes[format], quality);
    }
    if (canvas.convertToBlob !== void 0) {
      const blob = await canvas.convertToBlob({ type: imageTypes[format], quality });
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(blob);
      });
    }
    throw new Error("Extract.base64() requires ICanvas.toDataURL, ICanvas.toBlob, or ICanvas.convertToBlob to be implemented");
  }
  /**
   * Creates a Canvas element, renders the target to it and returns it.
   * This method is useful for creating static images or when you need direct canvas access.
   * @param options - The options for creating the canvas, or the target to extract
   * @returns A Canvas element with the texture rendered on
   * @example
   * ```ts
   * // Basic canvas extraction from a sprite
   * const sprite = new Sprite(texture);
   * const canvas = renderer.extract.canvas(sprite);
   * document.body.appendChild(canvas);
   *
   * // Extract with custom region
   * const canvas = renderer.extract.canvas({
   *     target: container,
   *     frame: new Rectangle(0, 0, 100, 100)
   * });
   *
   * // Extract with high resolution
   * const canvas = renderer.extract.canvas({
   *     target: sprite,
   *     resolution: 2,
   *     clearColor: '#ff0000'
   * });
   *
   * // Extract directly from a texture
   * const texture = Texture.from('myTexture.png');
   * const canvas = renderer.extract.canvas(texture);
   *
   * // Extract with anti-aliasing
   * const canvas = renderer.extract.canvas({
   *     target: graphics,
   *     antialias: true
   * });
   * ```
   * @see {@link ExtractOptions} For detailed options
   * @see {@link ExtractSystem.image} For HTMLImage output
   * @see {@link ExtractSystem.pixels} For raw pixel data
   * @category rendering
   */
  canvas(options) {
    options = this._normalizeOptions(options);
    const target = options.target;
    const renderer = this._renderer;
    if (target instanceof Texture.Texture) {
      return renderer.texture.generateCanvas(target);
    }
    const texture = renderer.textureGenerator.generateTexture(options);
    const canvas = renderer.texture.generateCanvas(texture);
    texture.destroy(true);
    return canvas;
  }
  /**
   * Returns a one-dimensional array containing the pixel data of the entire texture in RGBA order,
   * with integer values between 0 and 255 (inclusive).
   * > [!NOE] The returned array is a flat Uint8Array where every 4 values represent RGBA
   * @param options - The options for extracting the image, or the target to extract
   * @returns One-dimensional Uint8Array containing the pixel data in RGBA format
   * @example
   * ```ts
   * // Basic pixel extraction
   * const sprite = new Sprite(texture);
   * const pixels = renderer.extract.pixels(sprite);
   * console.log(pixels[0], pixels[1], pixels[2], pixels[3]); // R,G,B,A values
   *
   * // Extract with custom region
   * const pixels = renderer.extract.pixels({
   *     target: sprite,
   *     frame: new Rectangle(0, 0, 100, 100)
   * });
   *
   * // Extract with high resolution
   * const pixels = renderer.extract.pixels({
   *     target: sprite,
   *     resolution: 2
   * });
   * ```
   * @see {@link ExtractOptions} For detailed options
   * @see {@link ExtractSystem.canvas} For canvas output
   * @see {@link ExtractSystem.image} For image output
   * @category rendering
   */
  pixels(options) {
    options = this._normalizeOptions(options);
    const target = options.target;
    const renderer = this._renderer;
    const texture = target instanceof Texture.Texture ? target : renderer.textureGenerator.generateTexture(options);
    const pixelInfo = renderer.texture.getPixels(texture);
    if (target instanceof Container.Container) {
      texture.destroy(true);
    }
    return pixelInfo;
  }
  /**
   * Creates a texture from a display object or existing texture.
   *
   * This is useful for creating
   * reusable textures from rendered content or making copies of existing textures.
   * > [!NOTE] The returned texture should be destroyed when no longer needed
   * @param options - The options for creating the texture, or the target to extract
   * @returns A new texture containing the extracted content
   * @example
   * ```ts
   * // Basic texture extraction from a sprite
   * const sprite = new Sprite(texture);
   * const extractedTexture = renderer.extract.texture(sprite);
   *
   * // Extract with custom region
   * const regionTexture = renderer.extract.texture({
   *     target: container,
   *     frame: new Rectangle(0, 0, 100, 100)
   * });
   *
   * // Extract with high resolution
   * const hiResTexture = renderer.extract.texture({
   *     target: sprite,
   *     resolution: 2,
   *     clearColor: '#ff0000'
   * });
   *
   * // Create a new sprite from extracted texture
   * const newSprite = new Sprite(
   *     renderer.extract.texture({
   *         target: graphics,
   *         antialias: true
   *     })
   * );
   *
   * // Clean up when done
   * extractedTexture.destroy(true);
   * ```
   * @see {@link ExtractOptions} For detailed options
   * @see {@link Texture} For texture management
   * @see {@link GenerateTextureSystem} For texture generation
   * @category rendering
   */
  texture(options) {
    options = this._normalizeOptions(options);
    if (options.target instanceof Texture.Texture) return options.target;
    return this._renderer.textureGenerator.generateTexture(options);
  }
  /**
   * Extracts and downloads content from the renderer as an image file.
   * This is a convenient way to save screenshots or export rendered content.
   * > [!NOTE] The download will use PNG format regardless of the filename extension
   * @param options - The options for downloading and extracting the image, or the target to extract
   * @example
   * ```ts
   * // Basic download with default filename
   * const sprite = new Sprite(texture);
   * renderer.extract.download(sprite); // Downloads as 'image.png'
   *
   * // Download with custom filename
   * renderer.extract.download({
   *     target: sprite,
   *     filename: 'screenshot.png'
   * });
   *
   * // Download with custom region
   * renderer.extract.download({
   *     target: container,
   *     filename: 'region.png',
   *     frame: new Rectangle(0, 0, 100, 100)
   * });
   *
   * // Download with high resolution and background
   * renderer.extract.download({
   *     target: stage,
   *     filename: 'hd-screenshot.png',
   *     resolution: 2,
   *     clearColor: '#ff0000'
   * });
   *
   * // Download with anti-aliasing
   * renderer.extract.download({
   *     target: graphics,
   *     filename: 'smooth.png',
   *     antialias: true
   * });
   * ```
   * @see {@link ExtractDownloadOptions} For detailed options
   * @see {@link ExtractSystem.image} For creating images without download
   * @see {@link ExtractSystem.canvas} For canvas output
   * @category rendering
   */
  download(options) {
    options = this._normalizeOptions(options);
    const canvas = this.canvas(options);
    const link = document.createElement("a");
    link.download = options.filename ?? "image.png";
    link.href = canvas.toDataURL("image/png");
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  }
  /**
   * Logs the target to the console as an image. This is a useful way to debug what's happening in the renderer.
   * The image will be displayed in the browser's console using CSS background images.
   * @param options - The options for logging the image, or the target to log
   * @param options.width - The width of the logged image preview in the console (in pixels)
   * @example
   * ```ts
   * // Basic usage
   * const sprite = new Sprite(texture);
   * renderer.extract.log(sprite);
   * ```
   * @see {@link ExtractSystem.canvas} For getting raw canvas output
   * @see {@link ExtractSystem.pixels} For raw pixel data
   * @category rendering
   * @advanced
   */
  log(options) {
    const width = options.width ?? 200;
    options = this._normalizeOptions(options);
    const canvas = this.canvas(options);
    const base64 = canvas.toDataURL();
    console.log(`[Pixi Texture] ${canvas.width}px ${canvas.height}px`);
    const style = [
      "font-size: 1px;",
      `padding: ${width}px ${300}px;`,
      `background: url(${base64}) no-repeat;`,
      "background-size: contain;"
    ].join(" ");
    console.log("%c ", style);
  }
  destroy() {
    this._renderer = null;
  }
};
/** @ignore */
_ExtractSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem,
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "extract"
};
/**
 * Default options for image extraction.
 * @example
 * ```ts
 * // Customize default options
 * ExtractSystem.defaultImageOptions.format = 'webp';
 * ExtractSystem.defaultImageOptions.quality = 0.8;
 *
 * // Use defaults
 * const image = await renderer.extract.image(sprite);
 * ```
 */
_ExtractSystem.defaultImageOptions = {
  format: "png",
  quality: 1
};
let ExtractSystem = _ExtractSystem;

exports.ExtractSystem = ExtractSystem;
//# sourceMappingURL=ExtractSystem.js.map
