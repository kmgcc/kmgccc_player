import { Texture } from '../rendering/renderers/shared/texture/Texture.mjs';
import { Sprite } from '../scene/sprite/Sprite.mjs';
import { UPDATE_PRIORITY } from '../ticker/const.mjs';
import { Ticker } from '../ticker/Ticker.mjs';
import { GifSource } from './GifSource.mjs';

"use strict";
const _GifSprite = class _GifSprite extends Sprite {
  constructor(...args) {
    const options = args[0] instanceof GifSource ? { source: args[0] } : args[0];
    const {
      source,
      fps,
      loop,
      animationSpeed,
      autoPlay,
      autoUpdate,
      onComplete,
      onFrameChange,
      onLoop,
      ...rest
    } = Object.assign(
      {},
      _GifSprite.defaultOptions,
      options
    );
    super({ texture: Texture.EMPTY, ...rest });
    /**
     * Animation playback speed multiplier.
     * Higher values speed up the animation, lower values slow it down.
     * @default 1
     * @example
     * ```ts
     * const animation = new GifSprite({ source });
     * animation.animationSpeed = 2; // 2x speed
     * ```
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    this.animationSpeed = 1;
    /**
     * Whether to loop the animation.
     * If `false`, the animation will stop after the last frame.
     * @default true
     * @example
     * ```ts
     * const animation = new GifSprite({ source, loop: false });
     * ```
     */
    this.loop = true;
    /**
     * The total duration of animation in milliseconds.
     * This represents the length of one complete animation cycle.
     * @example
     * ```ts
     * // Get animation duration
     * const animation = new GifSprite({ source });
     * console.log('Duration:', animation.duration); // e.g. 1000 for 1 second
     * ```
     * @readonly
     * @default 0
     * @remarks
     * - Set during initialization from last frame's end time
     * - Used for progress calculation and loop timing
     * - Value is in milliseconds
     * - Cannot be modified after creation
     * @see {@link GifSprite.progress} For animation progress
     * @see {@link GifSprite.currentFrame} For current frame number
     */
    this.duration = 0;
    /**
     * Whether to start playing right away when created.
     * If `false`, you must call {@link GifSprite.play} to start playback.
     * @default true
     * @example
     * ```ts
     * const animation = new GifSprite({ source, autoPlay: true });
     * ```
     * @see {@link GifSprite.play}
     */
    this.autoPlay = true;
    /**
     * Dirty means the image needs to be redrawn. Set to `true` to force redraw.
     * @advanced
     */
    this.dirty = false;
    /** The current frame number (zero-based index). */
    this._currentFrame = 0;
    /** `true` uses {@link Ticker.shared} to auto update animation time.*/
    this._autoUpdate = false;
    /** `true` if the instance is currently connected to {@link Ticker.shared} to auto update animation time. */
    this._isConnectedToTicker = false;
    /** If animation is currently playing. */
    this._playing = false;
    /** Current playback position in milliseconds. */
    this._currentTime = 0;
    this.onRender = () => this._updateFrame();
    this.texture = source.textures[0];
    this.duration = source.frames[source.frames.length - 1].end;
    this._source = source;
    this._playing = false;
    this._currentTime = 0;
    this._isConnectedToTicker = false;
    Object.assign(this, {
      fps,
      loop,
      animationSpeed,
      autoPlay,
      autoUpdate,
      onComplete,
      onFrameChange,
      onLoop
    });
    this.currentFrame = 0;
    if (autoPlay) {
      this.play();
    }
  }
  /**
   * Stops the animation playback.
   * Halts at the current frame and disconnects from the ticker if auto-updating.
   * @example
   * ```ts
   * // Basic stop
   * const animation = new GifSprite({ source });
   * animation.stop();
   *
   * // Stop at specific frame
   * animation.currentFrame = 5;
   * animation.stop();
   *
   * // Stop and reset
   * animation.currentFrame = 0;
   * animation.stop();
   * ```
   * @remarks
   * - Does nothing if animation is already stopped
   * - Maintains current frame position
   * - Disconnects from shared ticker if auto-updating
   * - Can be resumed with play()
   * @see {@link GifSprite.play} For resuming playback
   * @see {@link GifSprite.currentFrame} For frame control
   */
  stop() {
    if (!this._playing) {
      return;
    }
    this._playing = false;
    if (this._autoUpdate && this._isConnectedToTicker) {
      Ticker.shared.remove(this.update, this);
      this._isConnectedToTicker = false;
    }
  }
  /**
   * Starts or resumes animation playback.
   * If animation is at the last frame and not looping, playback will restart from the beginning.
   * @example
   * ```ts
   * // Basic playback
   * const animation = new GifSprite({ source, autoPlay: false });
   * animation.play();
   *
   * // Play after stopping
   * animation.stop();
   * animation.play(); // Resumes from current frame
   *
   * // Play with auto-updating disabled
   * const animation = new GifSprite({
   *     source,
   *     autoPlay: false,
   *     autoUpdate: false
   * });
   * animation.play();
   * app.ticker.add((ticker) => {
   *     animation.update(ticker);
   * });
   * ```
   * @remarks
   * - Does nothing if animation is already playing
   * - Connects to shared ticker if autoUpdate is true
   * - Restarts from beginning if at last frame of non-looping animation
   * - Maintains current frame position otherwise
   * @see {@link GifSprite.stop} For stopping playback
   * @see {@link GifSprite.playing} For checking playback status
   * @see {@link GifSprite.autoUpdate} For controlling automatic updates
   */
  play() {
    if (this._playing) {
      return;
    }
    this._playing = true;
    if (this._autoUpdate && !this._isConnectedToTicker) {
      Ticker.shared.add(this.update, this, UPDATE_PRIORITY.HIGH);
      this._isConnectedToTicker = true;
    }
    if (!this.loop && this.currentFrame === this._source.frames.length - 1) {
      this._currentTime = 0;
    }
  }
  /**
   * Gets the current progress of the animation as a value between 0 and 1.
   * Useful for tracking animation completion and implementing progress bars.
   * @example
   * ```ts
   * // Basic progress tracking
   * const animation = new GifSprite({ source });
   * console.log('Progress:', Math.round(animation.progress * 100) + '%');
   *
   * // Update progress bar
   * app.ticker.add(() => {
   *     progressBar.width = animation.progress * 200; // 200px total width
   * });
   *
   * // Check if animation is near end
   * if (animation.progress > 0.9) {
   *     console.log('Animation almost complete!');
   * }
   * ```
   * @remarks
   * - Returns 0 at start
   * - Returns 1 when complete
   * - Updates continuously during playback
   * - Based on currentTime and total duration
   * @readonly
   * @see {@link GifSprite.duration} For total animation length
   */
  get progress() {
    return this._currentTime / this.duration;
  }
  /** `true` if the current animation is playing */
  get playing() {
    return this._playing;
  }
  /**
   * Updates the object transform for rendering.
   * This method is called automatically by the ticker if `autoUpdate` is enabled.
   * Only updates if the animation is currently playing.
   * > [!IMPORTANT] Call this manually when `autoUpdate` is set to `false` to control animation timing.
   * @param ticker - Ticker instance used to calculate frame timing
   * @example
   * ```ts
   * // Manual update with app ticker
   * const animation = new GifSprite({
   *     source,
   *     autoUpdate: false
   * });
   *
   * // Add to custom ticker
   * app.ticker.add(() => {
   *     animation.update(app.ticker);
   * });
   *
   * // Update with custom timing
   * const customTicker = new Ticker();
   * customTicker.add(() => {
   *     animation.update(customTicker);
   * });
   * ```
   * @see {@link GifSprite.autoUpdate} For automatic update control
   * @see {@link GifSprite.playing} For playback state
   * @see {@link Ticker} For timing system details
   */
  update(ticker) {
    if (!this._playing) {
      return;
    }
    const elapsed = this.animationSpeed * ticker.deltaTime / Ticker.targetFPMS;
    const currentTime = this._currentTime + elapsed;
    const localTime = currentTime % this.duration;
    const localFrame = this._source.frames.findIndex((frame) => frame.start <= localTime && frame.end > localTime);
    if (currentTime >= this.duration) {
      if (this.loop) {
        this._currentTime = localTime;
        this._updateFrameIndex(localFrame);
        this.onLoop?.();
      } else {
        this._currentTime = this.duration;
        this._updateFrameIndex(this.totalFrames - 1);
        this.onComplete?.();
        this.stop();
      }
    } else {
      this._currentTime = localTime;
      this._updateFrameIndex(localFrame);
    }
  }
  /** Redraw the current frame, is necessary for the animation to work when */
  _updateFrame() {
    if (!this.dirty) {
      return;
    }
    this.texture = this._source.frames[this._currentFrame].texture;
    this.dirty = false;
  }
  /**
   * Whether to use {@link Ticker.shared} to auto update animation time.
   * Controls if the animation updates automatically using the shared ticker.
   * @example
   * ```ts
   * // Using auto-update (default)
   * const animation = new GifSprite({
   *     source,
   *     autoUpdate: true
   * });
   *
   * // Manual updates
   * const animation = new GifSprite({
   *     source,
   *     autoUpdate: false
   * });
   *
   * // Custom update loop
   * app.ticker.add(() => {
   *     animation.update(app.ticker);
   * });
   *
   * // Switch update modes at runtime
   * animation.autoUpdate = false; // Disconnect from shared ticker
   * animation.autoUpdate = true;  // Reconnect if playing
   * ```
   * @default true
   * @see {@link GifSprite.update} For manual updating
   * @see {@link Ticker.shared} For the shared ticker instance
   */
  get autoUpdate() {
    return this._autoUpdate;
  }
  set autoUpdate(value) {
    if (value !== this._autoUpdate) {
      this._autoUpdate = value;
      if (!this._autoUpdate && this._isConnectedToTicker) {
        Ticker.shared.remove(this.update, this);
        this._isConnectedToTicker = false;
      } else if (this._autoUpdate && !this._isConnectedToTicker && this._playing) {
        Ticker.shared.add(this.update, this);
        this._isConnectedToTicker = true;
      }
    }
  }
  /**
   * Gets or sets the current frame number.
   * Controls which frame of the GIF animation is currently displayed.
   * @example
   * ```ts
   * // Get current frame
   * const animation = new GifSprite({ source });
   * console.log('Current frame:', animation.currentFrame);
   *
   * // Jump to specific frame
   * animation.currentFrame = 5;
   *
   * // Reset to first frame
   * animation.currentFrame = 0;
   *
   * // Get frame at specific progress
   * const frameAtProgress = Math.floor(animation.totalFrames * 0.5); // 50%
   * animation.currentFrame = frameAtProgress;
   * ```
   * @throws {Error} If frame index is out of range
   * @remarks
   * - Zero-based index (0 to totalFrames-1)
   * - Updates animation time to frame start
   * - Triggers frame change callback
   * - Marks sprite as dirty for redraw
   * @see {@link GifSprite.totalFrames} For frame count
   * @see {@link GifSprite.onFrameChange} For frame change events
   */
  get currentFrame() {
    return this._currentFrame;
  }
  set currentFrame(value) {
    this._updateFrameIndex(value);
    this._currentTime = this._source.frames[value].start;
  }
  /**
   * The source GIF data containing frame textures and timing information.
   * This represents the underlying animation data used by the sprite.
   * @example
   * ```ts
   * // Access source data
   * const animation = new GifSprite({ source });
   * const frameCount = animation.source.totalFrames;
   * const frameTexture = animation.source.textures[0];
   *
   * // Share source between sprites
   * const clone = new GifSprite({
   *     source: animation.source,
   *     autoPlay: false
   * });
   *
   * // Check source properties
   * console.log('Total frames:', animation.source.totalFrames);
   * console.log('Frame timing:', animation.source.frames);
   * ```
   * @remarks
   * - Contains all frame textures
   * - Manages frame timing data
   * - Can be shared between sprites
   * - Destroyed with sprite if destroyData=true
   * @readonly
   * @see {@link GifSource} For source data implementation
   * @see {@link GifSprite.clone} For creating independent instances
   */
  get source() {
    return this._source;
  }
  /**
   * Internally handle updating the frame index
   * @param value
   */
  _updateFrameIndex(value) {
    if (value < 0 || value >= this.totalFrames) {
      throw new Error(`Frame index out of range, expecting 0 to ${this.totalFrames}, got ${value}`);
    }
    if (this._currentFrame !== value) {
      this._currentFrame = value;
      this.dirty = true;
      this.onFrameChange?.(value);
    }
  }
  /**
   * Gets the total number of frames in the GIF animation.
   * @example
   * ```ts
   * // Get total frames
   * const animation = new GifSprite({ source });
   * console.log('Total frames:', animation.totalFrames);
   * ```
   * @readonly
   * @see {@link GifSprite.currentFrame} For current frame index
   * @see {@link GifSource.totalFrames} For source frame count
   */
  get totalFrames() {
    return this._source.totalFrames;
  }
  /**
   * Destroy and don't use after this.
   * @param destroyData - Destroy the data, cannot be used again.
   * @example
   * ```ts
   * const animation = new GifSprite({ source });
   * // Do something with animation...
   * animation.destroy(true); // Destroy the animation and its source data
   *
   * // If you want to keep the source data for reuse, use:
   * animation.destroy(false); // Destroy the animation but keep source data
   * ```
   */
  destroy(destroyData = false) {
    this.stop();
    super.destroy();
    if (destroyData) {
      this._source.destroy();
    }
    const forceClear = null;
    this._source = forceClear;
    this.onComplete = forceClear;
    this.onFrameChange = forceClear;
    this.onLoop = forceClear;
  }
  /**
   * Creates an independent copy of this GifSprite instance.
   * Useful for creating multiple animations that share the same source data
   * but can be controlled independently.
   * > [!IMPORTANT]
   * > The cloned sprite will have its own playback state, so you can play,
   * > pause, or seek it without affecting the original sprite.
   * @example
   * ```ts
   * // Create original animation
   * const animation = new GifSprite({ source });
   *
   * // Create independent clone
   * const clone = animation.clone();
   * clone.play();  // Plays independently
   * animation.stop(); // Original stops, clone continues
   *
   * // Clone with modified properties
   * const halfSpeed = animation.clone();
   * halfSpeed.animationSpeed = 0.5;
   * ```
   * @returns {GifSprite} A new GifSprite instance with the same properties
   * @see {@link GifSprite.source} For shared source data
   * @see {@link GifSprite.destroy} For cleanup
   */
  clone() {
    const clone = new _GifSprite({
      source: this._source,
      autoUpdate: this._autoUpdate,
      loop: this.loop,
      autoPlay: this.autoPlay,
      animationSpeed: this.animationSpeed,
      onComplete: this.onComplete,
      onFrameChange: this.onFrameChange,
      onLoop: this.onLoop
    });
    clone.dirty = true;
    return clone;
  }
};
/**
 * Default configuration options for GifSprite instances.
 *
 * These values are used when specific options are not provided to the constructor.
 * Each property can be overridden by passing it in the options object.
 * @example
 * ```ts
 * GifSprite.defaultOptions.fps = 24; // Change default FPS to 24
 * GifSprite.defaultOptions.loop = false; // Disable looping by default
 *
 * const animation = new GifSprite(); // Will use these defaults
 * ```
 */
_GifSprite.defaultOptions = {
  fps: 30,
  loop: true,
  animationSpeed: 1,
  autoPlay: true,
  autoUpdate: true,
  onComplete: null,
  onFrameChange: null,
  onLoop: null
};
let GifSprite = _GifSprite;

export { GifSprite };
//# sourceMappingURL=GifSprite.mjs.map
