import { Rectangle } from '../maths/shapes/Rectangle.mjs';
import { TextureSource } from '../rendering/renderers/shared/texture/sources/TextureSource.mjs';
import { Texture } from '../rendering/renderers/shared/texture/Texture.mjs';

"use strict";
const _Spritesheet = class _Spritesheet {
  constructor(optionsOrTexture, arg1) {
    /** For multi-packed spritesheets, this contains a reference to all the other spritesheets it depends on. */
    this.linkedSheets = [];
    let options = optionsOrTexture;
    if (optionsOrTexture?.source instanceof TextureSource) {
      options = {
        texture: optionsOrTexture,
        data: arg1
      };
    }
    const { texture, data, cachePrefix = "" } = options;
    this.cachePrefix = cachePrefix;
    this._texture = texture instanceof Texture ? texture : null;
    this.textureSource = texture.source;
    this.textures = {};
    this.animations = {};
    this.data = data;
    const metaResolution = parseFloat(data.meta.scale);
    if (metaResolution) {
      this.resolution = metaResolution;
      texture.source.resolution = this.resolution;
    } else {
      this.resolution = texture.source._resolution;
    }
    this._frames = this.data.frames;
    this._frameKeys = Object.keys(this._frames);
    this._batchIndex = 0;
    this._callback = null;
  }
  /**
   * Parse spritesheet from loaded data. This is done asynchronously
   * to prevent creating too many Texture within a single process.
   */
  parse() {
    return new Promise((resolve) => {
      this._callback = resolve;
      this._batchIndex = 0;
      if (this._frameKeys.length <= _Spritesheet.BATCH_SIZE) {
        this._processFrames(0);
        this._processAnimations();
        this._parseComplete();
      } else {
        this._nextBatch();
      }
    });
  }
  /**
   * Parse spritesheet from loaded data. This is done synchronously
   * and is only suitable for smaller spritesheets (less than ~1000 frames)
   * or may cause too many Texture within a single process. However, synchronous parsing may be
   * more convenient since the called does not need to be asynchronous and is safe for
   * small-to-medium sized spritesheets.
   *
   * Other than being synchronous, `parseSync` is otherwise identical to `.parse()`.
   */
  parseSync() {
    this._processFrames(0, true);
    this._processAnimations();
    return this.textures;
  }
  /**
   * Process a batch of frames
   * @param initialFrameIndex - The index of frame to start.
   * @param processAll - if true will process all frames in a single batch, ignoring BATCH_SIZE - this
   * is used for synchronous parsing.
   */
  _processFrames(initialFrameIndex, processAll = false) {
    let frameIndex = initialFrameIndex;
    const maxFrames = processAll ? Infinity : _Spritesheet.BATCH_SIZE;
    while (frameIndex - initialFrameIndex < maxFrames && frameIndex < this._frameKeys.length) {
      const i = this._frameKeys[frameIndex];
      const data = this._frames[i];
      const rect = data.frame;
      if (rect) {
        let frame = null;
        let trim = null;
        const sourceSize = data.trimmed !== false && data.sourceSize ? data.sourceSize : data.frame;
        const orig = new Rectangle(
          0,
          0,
          Math.floor(sourceSize.w) / this.resolution,
          Math.floor(sourceSize.h) / this.resolution
        );
        if (data.rotated) {
          frame = new Rectangle(
            Math.floor(rect.x) / this.resolution,
            Math.floor(rect.y) / this.resolution,
            Math.floor(rect.h) / this.resolution,
            Math.floor(rect.w) / this.resolution
          );
        } else {
          frame = new Rectangle(
            Math.floor(rect.x) / this.resolution,
            Math.floor(rect.y) / this.resolution,
            Math.floor(rect.w) / this.resolution,
            Math.floor(rect.h) / this.resolution
          );
        }
        if (data.trimmed !== false && data.spriteSourceSize) {
          trim = new Rectangle(
            Math.floor(data.spriteSourceSize.x) / this.resolution,
            Math.floor(data.spriteSourceSize.y) / this.resolution,
            Math.floor(rect.w) / this.resolution,
            Math.floor(rect.h) / this.resolution
          );
        }
        this.textures[i] = new Texture({
          source: this.textureSource,
          frame,
          orig,
          trim,
          rotate: data.rotated ? 2 : 0,
          defaultAnchor: data.anchor,
          defaultBorders: data.borders,
          label: i.toString()
        });
      }
      frameIndex++;
    }
  }
  /** Parse animations config. */
  _processAnimations() {
    const animations = this.data.animations || {};
    for (const animName in animations) {
      this.animations[animName] = [];
      for (let i = 0; i < animations[animName].length; i++) {
        const frameName = animations[animName][i];
        this.animations[animName].push(this.textures[frameName]);
      }
    }
  }
  /** The parse has completed. */
  _parseComplete() {
    const callback = this._callback;
    this._callback = null;
    this._batchIndex = 0;
    callback.call(this, this.textures);
  }
  /** Begin the next batch of textures. */
  _nextBatch() {
    this._processFrames(this._batchIndex * _Spritesheet.BATCH_SIZE);
    this._batchIndex++;
    setTimeout(() => {
      if (this._batchIndex * _Spritesheet.BATCH_SIZE < this._frameKeys.length) {
        this._nextBatch();
      } else {
        this._processAnimations();
        this._parseComplete();
      }
    }, 0);
  }
  /**
   * Destroy Spritesheet and don't use after this.
   * @param {boolean} [destroyBase=false] - Whether to destroy the base texture as well
   */
  destroy(destroyBase = false) {
    for (const i in this.textures) {
      this.textures[i].destroy();
    }
    this._frames = null;
    this._frameKeys = null;
    this.data = null;
    this.textures = null;
    if (destroyBase) {
      this._texture?.destroy();
      this.textureSource.destroy();
    }
    this._texture = null;
    this.textureSource = null;
    this.linkedSheets = [];
  }
};
/**
 * The maximum number of Textures to build per process.
 * @advanced
 */
_Spritesheet.BATCH_SIZE = 1e3;
let Spritesheet = _Spritesheet;

export { Spritesheet };
//# sourceMappingURL=Spritesheet.mjs.map
