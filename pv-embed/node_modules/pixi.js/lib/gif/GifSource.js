'use strict';

var gifuctJs = require('gifuct-js');
var adapter = require('../environment/adapter.js');
var CanvasSource = require('../rendering/renderers/shared/texture/sources/CanvasSource.js');
var Texture = require('../rendering/renderers/shared/texture/Texture.js');

"use strict";
class GifSource {
  /**
   * @param frames - Array of GifFrame instances.
   */
  constructor(frames) {
    if (!frames || !frames.length) throw new Error("Invalid frames");
    const [{ texture: { width, height } }] = frames;
    this.width = width;
    this.height = height;
    this.frames = frames;
    this.textures = this.frames.map((frame) => frame.texture);
    this.totalFrames = this.frames.length;
    this.duration = this.frames[this.totalFrames - 1].end;
  }
  /** Destroy animation data and don't use after this */
  destroy() {
    for (const texture of this.textures) {
      texture.destroy(true);
    }
    for (const frame of this.frames) {
      frame.texture = null;
    }
    this.frames.length = 0;
    this.textures.length = 0;
    Object.assign(this, {
      frames: null,
      textures: null,
      width: 0,
      height: 0,
      duration: 0,
      totalFrames: 0
    });
  }
  /**
   * Create an animated GIF animation from a GIF image's ArrayBuffer. The easiest way to get
   * the buffer is to use Assets.
   * @example
   * import { GifSource, GifSprite } from 'pixi.js/gif';
   *
   * const buffer = await fetch('./file.gif').then(res => res.arrayBuffer());
   * const source = GifSource.from(buffer);
   * const sprite = new GifSprite(source);
   * @param buffer - GIF image arraybuffer from Assets.
   * @param options - Optional options to use when building from buffer.
   */
  static from(buffer, options) {
    if (!buffer || buffer.byteLength === 0) {
      throw new Error("Invalid buffer");
    }
    const validateAndFix = (gif2) => {
      let currentGce = null;
      for (const frame of gif2.frames) {
        currentGce = frame.gce ?? currentGce;
        if ("image" in frame && !("gce" in frame)) {
          frame.gce = currentGce;
        }
      }
    };
    const gif = gifuctJs.parseGIF(buffer);
    validateAndFix(gif);
    const gifFrames = gifuctJs.decompressFrames(gif, true);
    const frames = [];
    const animWidth = gif.lsd.width;
    const animHeight = gif.lsd.height;
    const canvas = adapter.DOMAdapter.get().createCanvas(animWidth, animHeight);
    const context = canvas.getContext("2d", { willReadFrequently: true });
    const patchCanvas = adapter.DOMAdapter.get().createCanvas();
    const patchContext = patchCanvas.getContext("2d");
    let time = 0;
    let previousFrame = null;
    const { fps = 30, ...canvasSourceOptions } = options ?? {};
    const defaultDelay = 1e3 / fps;
    for (let i = 0; i < gifFrames.length; i++) {
      const {
        disposalType = 2,
        delay = defaultDelay,
        patch,
        dims: { width, height, left, top }
      } = gifFrames[i];
      patchCanvas.width = width;
      patchCanvas.height = height;
      patchContext.clearRect(0, 0, width, height);
      const patchData = patchContext.createImageData(width, height);
      patchData.data.set(patch);
      patchContext.putImageData(patchData, 0, 0);
      if (disposalType === 3) {
        previousFrame = context.getImageData(0, 0, animWidth, animHeight);
      }
      context.drawImage(patchCanvas, left, top);
      const imageData = context.getImageData(0, 0, animWidth, animHeight);
      if (disposalType === 2) {
        context.clearRect(0, 0, animWidth, animHeight);
      } else if (disposalType === 3) {
        context.putImageData(previousFrame, 0, 0);
      }
      const resource = adapter.DOMAdapter.get().createCanvas(
        imageData.width,
        imageData.height
      );
      const resourceContext = resource.getContext("2d");
      resourceContext.putImageData(imageData, 0, 0);
      frames.push({
        start: time,
        end: time + delay,
        texture: new Texture.Texture({
          source: new CanvasSource.CanvasSource({
            resource,
            ...canvasSourceOptions
          })
        })
      });
      time += delay;
    }
    canvas.width = canvas.height = 0;
    patchCanvas.width = patchCanvas.height = 0;
    return new GifSource(frames);
  }
}

exports.GifSource = GifSource;
//# sourceMappingURL=GifSource.js.map
