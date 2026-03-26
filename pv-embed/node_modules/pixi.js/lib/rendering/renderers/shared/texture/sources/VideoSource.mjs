import { ExtensionType } from '../../../../../extensions/Extensions.mjs';
import { Ticker } from '../../../../../ticker/Ticker.mjs';
import { detectVideoAlphaMode } from '../../../../../utils/browser/detectVideoAlphaMode.mjs';
import { TextureSource } from './TextureSource.mjs';

"use strict";
const _VideoSource = class _VideoSource extends TextureSource {
  constructor(options) {
    super(options);
    // Public
    /** Whether or not the video is ready to play. */
    this.isReady = false;
    /** The upload method for this texture. */
    this.uploadMethodId = "video";
    options = {
      ..._VideoSource.defaultOptions,
      ...options
    };
    this._autoUpdate = true;
    this._isConnectedToTicker = false;
    this._updateFPS = options.updateFPS || 0;
    this._msToNextUpdate = 0;
    this.autoPlay = options.autoPlay !== false;
    this.alphaMode = options.alphaMode ?? "premultiply-alpha-on-upload";
    this._videoFrameRequestCallback = this._videoFrameRequestCallback.bind(this);
    this._videoFrameRequestCallbackHandle = null;
    this._load = null;
    this._resolve = null;
    this._reject = null;
    this._onCanPlay = this._onCanPlay.bind(this);
    this._onCanPlayThrough = this._onCanPlayThrough.bind(this);
    this._onError = this._onError.bind(this);
    this._onPlayStart = this._onPlayStart.bind(this);
    this._onPlayStop = this._onPlayStop.bind(this);
    this._onSeeked = this._onSeeked.bind(this);
    if (options.autoLoad !== false) {
      void this.load();
    }
  }
  /** Update the video frame if the source is not destroyed and meets certain conditions. */
  updateFrame() {
    if (this.destroyed) {
      return;
    }
    if (this._updateFPS) {
      const elapsedMS = Ticker.shared.elapsedMS * this.resource.playbackRate;
      this._msToNextUpdate = Math.floor(this._msToNextUpdate - elapsedMS);
    }
    if (!this._updateFPS || this._msToNextUpdate <= 0) {
      this._msToNextUpdate = this._updateFPS ? Math.floor(1e3 / this._updateFPS) : 0;
    }
    if (this.isValid) {
      this.update();
    }
  }
  /** Callback to update the video frame and potentially request the next frame update. */
  _videoFrameRequestCallback() {
    this.updateFrame();
    if (this.destroyed) {
      this._videoFrameRequestCallbackHandle = null;
    } else {
      this._videoFrameRequestCallbackHandle = this.resource.requestVideoFrameCallback(
        this._videoFrameRequestCallback
      );
    }
  }
  /**
   * Checks if the resource has valid dimensions.
   * @returns {boolean} True if width and height are set, otherwise false.
   */
  get isValid() {
    return !!this.resource.videoWidth && !!this.resource.videoHeight;
  }
  /**
   * Start preloading the video resource.
   * @returns {Promise<this>} Handle the validate event
   */
  async load() {
    if (this._load) {
      return this._load;
    }
    const source = this.resource;
    const options = this.options;
    if ((source.readyState === source.HAVE_ENOUGH_DATA || source.readyState === source.HAVE_FUTURE_DATA) && source.width && source.height) {
      source.complete = true;
    }
    source.addEventListener("play", this._onPlayStart);
    source.addEventListener("pause", this._onPlayStop);
    source.addEventListener("seeked", this._onSeeked);
    if (!this._isSourceReady()) {
      if (!options.preload) {
        source.addEventListener("canplay", this._onCanPlay);
      }
      source.addEventListener("canplaythrough", this._onCanPlayThrough);
      source.addEventListener("error", this._onError, true);
    } else {
      this._mediaReady();
    }
    this.alphaMode = await detectVideoAlphaMode();
    this._load = new Promise((resolve, reject) => {
      if (this.isValid) {
        resolve(this);
      } else {
        this._resolve = resolve;
        this._reject = reject;
        if (options.preloadTimeoutMs !== void 0) {
          this._preloadTimeout = setTimeout(() => {
            this._onError(new ErrorEvent(`Preload exceeded timeout of ${options.preloadTimeoutMs}ms`));
          });
        }
        source.load();
      }
    });
    return this._load;
  }
  /**
   * Handle video error events.
   * @param event - The error event
   */
  _onError(event) {
    this.resource.removeEventListener("error", this._onError, true);
    this.emit("error", event);
    if (this._reject) {
      this._reject(event);
      this._reject = null;
      this._resolve = null;
    }
  }
  /**
   * Checks if the underlying source is playing.
   * @returns True if playing.
   */
  _isSourcePlaying() {
    const source = this.resource;
    return !source.paused && !source.ended;
  }
  /**
   * Checks if the underlying source is ready for playing.
   * @returns True if ready.
   */
  _isSourceReady() {
    const source = this.resource;
    return source.readyState > 2;
  }
  /** Runs the update loop when the video is ready to play. */
  _onPlayStart() {
    if (!this.isValid) {
      this._mediaReady();
    }
    this._configureAutoUpdate();
  }
  /** Stops the update loop when a pause event is triggered. */
  _onPlayStop() {
    this._configureAutoUpdate();
  }
  /** Handles behavior when the video completes seeking to the current playback position. */
  _onSeeked() {
    if (this._autoUpdate && !this._isSourcePlaying()) {
      this._msToNextUpdate = 0;
      this.updateFrame();
      this._msToNextUpdate = 0;
    }
  }
  _onCanPlay() {
    const source = this.resource;
    source.removeEventListener("canplay", this._onCanPlay);
    this._mediaReady();
  }
  _onCanPlayThrough() {
    const source = this.resource;
    source.removeEventListener("canplaythrough", this._onCanPlay);
    if (this._preloadTimeout) {
      clearTimeout(this._preloadTimeout);
      this._preloadTimeout = void 0;
    }
    this._mediaReady();
  }
  /** Fired when the video is loaded and ready to play. */
  _mediaReady() {
    const source = this.resource;
    if (this.isValid) {
      this.isReady = true;
      this.resize(source.videoWidth, source.videoHeight);
    }
    this._msToNextUpdate = 0;
    this.updateFrame();
    this._msToNextUpdate = 0;
    if (this._resolve) {
      this._resolve(this);
      this._resolve = null;
      this._reject = null;
    }
    if (this._isSourcePlaying()) {
      this._onPlayStart();
    } else if (this.autoPlay) {
      void this.resource.play();
    }
  }
  /** Cleans up resources and event listeners associated with this texture. */
  destroy() {
    this._configureAutoUpdate();
    const source = this.resource;
    if (source) {
      source.removeEventListener("play", this._onPlayStart);
      source.removeEventListener("pause", this._onPlayStop);
      source.removeEventListener("seeked", this._onSeeked);
      source.removeEventListener("canplay", this._onCanPlay);
      source.removeEventListener("canplaythrough", this._onCanPlayThrough);
      source.removeEventListener("error", this._onError, true);
      source.pause();
      source.src = "";
      source.load();
    }
    super.destroy();
  }
  /** Should the base texture automatically update itself, set to true by default. */
  get autoUpdate() {
    return this._autoUpdate;
  }
  set autoUpdate(value) {
    if (value !== this._autoUpdate) {
      this._autoUpdate = value;
      this._configureAutoUpdate();
    }
  }
  /**
   * How many times a second to update the texture from the video.
   * Leave at 0 to update at every render.
   * A lower fps can help performance, as updating the texture at 60fps on a 30ps video may not be efficient.
   */
  get updateFPS() {
    return this._updateFPS;
  }
  set updateFPS(value) {
    if (value !== this._updateFPS) {
      this._updateFPS = value;
      this._configureAutoUpdate();
    }
  }
  /**
   * Configures the updating mechanism based on the current state and settings.
   *
   * This method decides between using the browser's native video frame callback or a custom ticker
   * for updating the video frame. It ensures optimal performance and responsiveness
   * based on the video's state, playback status, and the desired frames-per-second setting.
   *
   * - If `_autoUpdate` is enabled and the video source is playing:
   *   - It will prefer the native video frame callback if available and no specific FPS is set.
   *   - Otherwise, it will use a custom ticker for manual updates.
   * - If `_autoUpdate` is disabled or the video isn't playing, any active update mechanisms are halted.
   */
  _configureAutoUpdate() {
    if (this._autoUpdate && this._isSourcePlaying()) {
      if (!this._updateFPS && this.resource.requestVideoFrameCallback) {
        if (this._isConnectedToTicker) {
          Ticker.shared.remove(this.updateFrame, this);
          this._isConnectedToTicker = false;
          this._msToNextUpdate = 0;
        }
        if (this._videoFrameRequestCallbackHandle === null) {
          this._videoFrameRequestCallbackHandle = this.resource.requestVideoFrameCallback(
            this._videoFrameRequestCallback
          );
        }
      } else {
        if (this._videoFrameRequestCallbackHandle !== null) {
          this.resource.cancelVideoFrameCallback(this._videoFrameRequestCallbackHandle);
          this._videoFrameRequestCallbackHandle = null;
        }
        if (!this._isConnectedToTicker) {
          Ticker.shared.add(this.updateFrame, this);
          this._isConnectedToTicker = true;
          this._msToNextUpdate = 0;
        }
      }
    } else {
      if (this._videoFrameRequestCallbackHandle !== null) {
        this.resource.cancelVideoFrameCallback(this._videoFrameRequestCallbackHandle);
        this._videoFrameRequestCallbackHandle = null;
      }
      if (this._isConnectedToTicker) {
        Ticker.shared.remove(this.updateFrame, this);
        this._isConnectedToTicker = false;
        this._msToNextUpdate = 0;
      }
    }
  }
  static test(resource) {
    return globalThis.HTMLVideoElement && resource instanceof HTMLVideoElement;
  }
};
_VideoSource.extension = ExtensionType.TextureSource;
/** The default options for video sources. */
_VideoSource.defaultOptions = {
  ...TextureSource.defaultOptions,
  /** If true, the video will start loading immediately. */
  autoLoad: true,
  /** If true, the video will start playing as soon as it is loaded. */
  autoPlay: true,
  /** The number of times a second to update the texture from the video. Leave at 0 to update at every render. */
  updateFPS: 0,
  /** If true, the video will be loaded with the `crossorigin` attribute. */
  crossorigin: true,
  /** If true, the video will loop when it ends. */
  loop: false,
  /** If true, the video will be muted. */
  muted: true,
  /** If true, the video will play inline. */
  playsinline: true,
  /** If true, the video will be preloaded. */
  preload: false
};
/**
 * Map of video MIME types that can't be directly derived from file extensions.
 * @readonly
 */
_VideoSource.MIME_TYPES = {
  ogv: "video/ogg",
  mov: "video/quicktime",
  m4v: "video/mp4"
};
let VideoSource = _VideoSource;

export { VideoSource };
//# sourceMappingURL=VideoSource.mjs.map
