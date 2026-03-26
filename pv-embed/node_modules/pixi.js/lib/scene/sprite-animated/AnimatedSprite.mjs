import { Texture } from '../../rendering/renderers/shared/texture/Texture.mjs';
import { UPDATE_PRIORITY } from '../../ticker/const.mjs';
import { Ticker } from '../../ticker/Ticker.mjs';
import { Sprite } from '../sprite/Sprite.mjs';

"use strict";
class AnimatedSprite extends Sprite {
  constructor(...args) {
    let options = args[0];
    if (Array.isArray(args[0])) {
      options = {
        textures: args[0],
        autoUpdate: args[1]
      };
    }
    const {
      animationSpeed = 1,
      autoPlay = false,
      autoUpdate = true,
      loop = true,
      onComplete = null,
      onFrameChange = null,
      onLoop = null,
      textures,
      updateAnchor = false,
      ...rest
    } = options;
    const [firstFrame] = textures;
    super({
      ...rest,
      texture: firstFrame instanceof Texture ? firstFrame : firstFrame.texture
    });
    this._textures = null;
    this._durations = null;
    this._autoUpdate = autoUpdate;
    this._isConnectedToTicker = false;
    this.animationSpeed = animationSpeed;
    this.loop = loop;
    this.updateAnchor = updateAnchor;
    this.onComplete = onComplete;
    this.onFrameChange = onFrameChange;
    this.onLoop = onLoop;
    this._currentTime = 0;
    this._playing = false;
    this._previousFrame = null;
    this.textures = textures;
    if (autoPlay) {
      this.play();
    }
  }
  /**
   * Stops the animation playback and freezes the current frame.
   * Does not reset the current frame or animation progress.
   * @example
   * ```ts
   * // Create an animated sprite
   * const sprite = new AnimatedSprite({
   *     textures: [
   *         Texture.from('walk1.png'),
   *         Texture.from('walk2.png'),
   *         Texture.from('walk3.png')
   *     ],
   *     autoPlay: true
   * });
   *
   * // Stop at current frame
   * sprite.stop();
   *
   * // Stop at specific frame
   * sprite.gotoAndStop(1); // Stops at second frame
   *
   * // Stop and reset
   * sprite.stop();
   * sprite.currentFrame = 0;
   *
   * // Stop with completion check
   * if (sprite.playing) {
   *     sprite.stop();
   *     sprite.onComplete?.();
   * }
   * ```
   * @see {@link AnimatedSprite#play} For starting playback
   * @see {@link AnimatedSprite#gotoAndStop} For stopping at a specific frame
   * @see {@link AnimatedSprite#playing} For checking play state
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
   * Starts or resumes the animation playback.
   * If the animation was previously stopped, it will continue from where it left off.
   * @example
   * ```ts
   * // Basic playback
   * const sprite = new AnimatedSprite({
   *     textures: [
   *         Texture.from('walk1.png'),
   *         Texture.from('walk2.png'),
   *     ],
   *     autoPlay: false
   * });
   * sprite.play();
   *
   * // Play after stopping
   * sprite.stop();
   * sprite.currentFrame = 0; // Reset to start
   * sprite.play(); // Play from beginning
   *
   * // Play with auto-update disabled
   * sprite.autoUpdate = false;
   * sprite.play();
   * app.ticker.add(() => {
   *     sprite.update(app.ticker); // Manual updates
   * });
   * ```
   * @see {@link AnimatedSprite#stop} For stopping playback
   * @see {@link AnimatedSprite#gotoAndPlay} For playing from a specific frame
   * @see {@link AnimatedSprite#playing} For checking play state
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
  }
  /**
   * Stops the AnimatedSprite and sets it to a specific frame.
   * @example
   * ```ts
   * // Create an animated sprite
   * const sprite = new AnimatedSprite({
   *     textures: [
   *         Texture.from('walk1.png'),
   *         Texture.from('walk2.png'),
   *         Texture.from('walk3.png'),
   *     ]
   * });
   *
   * // Go to specific frames
   * sprite.gotoAndStop(0);  // First frame
   * sprite.gotoAndStop(2);  // Third frame
   *
   * // Jump to last frame
   * sprite.gotoAndStop(sprite.totalFrames - 1);
   * ```
   * @param frameNumber - Frame index to stop at (0-based)
   * @throws {Error} If frameNumber is out of bounds
   * @see {@link AnimatedSprite#gotoAndPlay} For going to a frame and playing
   * @see {@link AnimatedSprite#currentFrame} For getting/setting current frame
   * @see {@link AnimatedSprite#totalFrames} For total number of frames
   */
  gotoAndStop(frameNumber) {
    this.stop();
    this.currentFrame = frameNumber;
  }
  /**
   * Goes to a specific frame and begins playing the AnimatedSprite from that point.
   * Combines frame navigation and playback start in one operation.
   * @example
   * ```ts
   * // Start from specific frame
   * sprite.gotoAndPlay(1); // Starts playing from second frame
   * ```
   * @param frameNumber - Frame index to start playing from (0-based)
   * @throws {Error} If frameNumber is out of bounds
   * @see {@link AnimatedSprite#gotoAndStop} For going to a frame without playing
   * @see {@link AnimatedSprite#play} For playing from current frame
   * @see {@link AnimatedSprite#currentFrame} For getting/setting current frame
   */
  gotoAndPlay(frameNumber) {
    this.currentFrame = frameNumber;
    this.play();
  }
  /**
   * Updates the object transform for rendering. This method handles animation timing, frame updates,
   * and manages looping behavior.
   * @example
   * ```ts
   * // Create an animated sprite with manual updates
   * const sprite = new AnimatedSprite({
   *     textures: [
   *         Texture.from('frame1.png'),
   *         Texture.from('frame2.png'),
   *         Texture.from('frame3.png')
   *     ],
   *     autoUpdate: false // Disable automatic updates
   * });
   *
   * // Manual update with app ticker
   * app.ticker.add((ticker) => {
   *     sprite.update(ticker);
   * });
   * ```
   * @param ticker - The ticker to use for updating the animation timing
   * @see {@link AnimatedSprite#autoUpdate} For controlling automatic updates
   * @see {@link AnimatedSprite#animationSpeed} For controlling animation speed
   * @see {@link Ticker} For timing system details
   */
  update(ticker) {
    if (!this._playing) {
      return;
    }
    const deltaTime = ticker.deltaTime;
    const elapsed = this.animationSpeed * deltaTime;
    const previousFrame = this.currentFrame;
    if (this._durations !== null) {
      let lag = this._currentTime % 1 * this._durations[this.currentFrame];
      lag += elapsed / 60 * 1e3;
      while (lag < 0) {
        this._currentTime--;
        lag += this._durations[this.currentFrame];
      }
      const sign = Math.sign(this.animationSpeed * deltaTime);
      this._currentTime = Math.floor(this._currentTime);
      while (lag >= this._durations[this.currentFrame]) {
        lag -= this._durations[this.currentFrame] * sign;
        this._currentTime += sign;
      }
      this._currentTime += lag / this._durations[this.currentFrame];
    } else {
      this._currentTime += elapsed;
    }
    if (this._currentTime < 0 && !this.loop) {
      this.gotoAndStop(0);
      if (this.onComplete) {
        this.onComplete();
      }
    } else if (this._currentTime >= this._textures.length && !this.loop) {
      this.gotoAndStop(this._textures.length - 1);
      if (this.onComplete) {
        this.onComplete();
      }
    } else if (previousFrame !== this.currentFrame) {
      if (this.loop && this.onLoop) {
        if (this.animationSpeed > 0 && this.currentFrame < previousFrame || this.animationSpeed < 0 && this.currentFrame > previousFrame) {
          this.onLoop();
        }
      }
      this._updateTexture();
    }
  }
  /** Updates the displayed texture to match the current frame index. */
  _updateTexture() {
    const currentFrame = this.currentFrame;
    if (this._previousFrame === currentFrame) {
      return;
    }
    this._previousFrame = currentFrame;
    this.texture = this._textures[currentFrame];
    if (this.updateAnchor && this.texture.defaultAnchor) {
      this.anchor.copyFrom(this.texture.defaultAnchor);
    }
    if (this.onFrameChange) {
      this.onFrameChange(this.currentFrame);
    }
  }
  /**
   * Stops the AnimatedSprite and destroys it.
   * This method stops the animation playback, removes it from the ticker,
   * and cleans up any resources associated with the sprite.
   * @param options - Options for destroying the sprite, such as whether to remove from parent
   * @example
   * ```ts
   * // Destroy the sprite when done
   * sprite.destroy();
   * // Or with options
   * sprite.destroy({ children: true, texture: true, textureSource: true });
   * ```
   */
  destroy(options = false) {
    const destroyTexture = typeof options === "boolean" ? options : options?.texture;
    if (destroyTexture) {
      const destroyTextureSource = typeof options === "boolean" ? options : options?.textureSource;
      this._textures.forEach((texture) => {
        if (this.texture !== texture) {
          texture.destroy(destroyTextureSource);
        }
      });
    }
    this._textures = [];
    this._durations = null;
    this.stop();
    super.destroy(options);
    this.onComplete = null;
    this.onFrameChange = null;
    this.onLoop = null;
  }
  /**
   * A short hand way of creating an AnimatedSprite from an array of frame ids.
   * Uses texture frames from the cache to create an animation sequence.
   * @example
   * ```ts
   * // Create from frame IDs
   * const frameIds = [
   *     'walk_001.png',
   *     'walk_002.png',
   *     'walk_003.png'
   * ];
   *
   * const walkingAnimation = AnimatedSprite.fromFrames(frameIds);
   * walkingAnimation.play();
   * ```
   * @param frames - The array of frame ids to use for the animation
   * @returns A new animated sprite using the frames
   * @see {@link Texture.from} For texture creation from frames
   * @see {@link Spritesheet} For loading spritesheets
   */
  static fromFrames(frames) {
    const textures = [];
    for (let i = 0; i < frames.length; ++i) {
      textures.push(Texture.from(frames[i]));
    }
    return new AnimatedSprite(textures);
  }
  /**
   * A short hand way of creating an AnimatedSprite from an array of image urls.
   * Each image will be used as a frame in the animation.
   * @example
   * ```ts
   * // Create from image URLs
   * const images = [
   *     'assets/walk1.png',
   *     'assets/walk2.png',
   *     'assets/walk3.png'
   * ];
   *
   * const walkingSprite = AnimatedSprite.fromImages(images);
   * walkingSprite.play();
   * ```
   * @param images - The array of image urls to use as frames
   * @returns A new animated sprite using the images as frames
   * @see {@link Assets} For asset loading and management
   * @see {@link Texture.from} For texture creation from images
   */
  static fromImages(images) {
    const textures = [];
    for (let i = 0; i < images.length; ++i) {
      textures.push(Texture.from(images[i]));
    }
    return new AnimatedSprite(textures);
  }
  /**
   * The total number of frames in the AnimatedSprite. This is the same as number of textures
   * assigned to the AnimatedSprite.
   * @example
   * ```ts
   * // Create an animated sprite
   * const sprite = new AnimatedSprite({
   *     textures: [
   *         Texture.from('frame1.png'),
   *         Texture.from('frame2.png'),
   *         Texture.from('frame3.png')
   *     ]
   * });
   *
   * // Get total frames
   * console.log(sprite.totalFrames); // Outputs: 3
   *
   * // Use with frame navigation
   * sprite.gotoAndStop(sprite.totalFrames - 1); // Go to last frame
   * ```
   * @readonly
   * @see {@link AnimatedSprite#currentFrame} For the current frame index
   * @see {@link AnimatedSprite#textures} For the array of textures
   * @returns {number} The total number of frames
   */
  get totalFrames() {
    return this._textures.length;
  }
  /**
   * The array of textures or frame objects used for the animation sequence.
   * Can be set to either an array of Textures or an array of FrameObjects with custom timing.
   * @example
   * ```ts
   * // Update textures at runtime
   * sprite.textures = [
   *     Texture.from('run1.png'),
   *     Texture.from('run2.png')
   * ];
   *
   * // Use custom frame timing
   * sprite.textures = [
   *     { texture: Texture.from('explosion1.png'), time: 100 },
   *     { texture: Texture.from('explosion2.png'), time: 200 },
   *     { texture: Texture.from('explosion3.png'), time: 300 }
   * ];
   *
   * // Use with spritesheet
   * const sheet = await Assets.load('animations.json');
   * sprite.textures = sheet.animations['walk'];
   * ```
   * @type {AnimatedSpriteFrames}
   * @see {@link FrameObject} For frame timing options
   * @see {@link Spritesheet} For loading from spritesheets
   */
  get textures() {
    return this._textures;
  }
  set textures(value) {
    if (value[0] instanceof Texture) {
      this._textures = value;
      this._durations = null;
    } else {
      this._textures = [];
      this._durations = [];
      for (let i = 0; i < value.length; i++) {
        this._textures.push(value[i].texture);
        this._durations.push(value[i].time);
      }
    }
    this._previousFrame = null;
    this.gotoAndStop(0);
    this._updateTexture();
  }
  /**
   * Gets or sets the current frame index of the animation.
   * When setting, the value will be clamped between 0 and totalFrames - 1.
   * @example
   * ```ts
   * // Create an animated sprite
   * const sprite = new AnimatedSprite({
   *     textures: [
   *         Texture.from('walk1.png'),
   *         Texture.from('walk2.png'),
   *         Texture.from('walk3.png')
   *     ]
   * });
   *
   * // Get current frame
   * console.log(sprite.currentFrame); // 0
   *
   * // Set specific frame
   * sprite.currentFrame = 1; // Show second frame
   *
   * // Use with frame callbacks
   * sprite.onFrameChange = (frame) => {
   *     console.log(`Now showing frame: ${frame}`);
   * };
   * sprite.currentFrame = 2;
   * ```
   * @throws {Error} If attempting to set a frame index out of bounds
   * @see {@link AnimatedSprite#totalFrames} For the total number of frames
   * @see {@link AnimatedSprite#gotoAndPlay} For playing from a specific frame
   * @see {@link AnimatedSprite#gotoAndStop} For stopping at a specific frame
   */
  get currentFrame() {
    let currentFrame = Math.floor(this._currentTime) % this._textures.length;
    if (currentFrame < 0) {
      currentFrame += this._textures.length;
    }
    return currentFrame;
  }
  set currentFrame(value) {
    if (value < 0 || value > this.totalFrames - 1) {
      throw new Error(`[AnimatedSprite]: Invalid frame index value ${value}, expected to be between 0 and totalFrames ${this.totalFrames}.`);
    }
    const previousFrame = this.currentFrame;
    this._currentTime = value;
    if (previousFrame !== this.currentFrame) {
      this._updateTexture();
    }
  }
  /**
   * Indicates if the AnimatedSprite is currently playing.
   * This is a read-only property that reflects the current playback state.
   * @example
   * ```ts
   * // Check if animation is playing
   * console.log('Playing:', sprite.playing); // true
   *
   * // Use with play control
   * if (!sprite.playing) {
   *     sprite.play();
   * }
   * ```
   * @readonly
   * @returns {boolean} True if the animation is currently playing
   * @see {@link AnimatedSprite#play} For starting playback
   * @see {@link AnimatedSprite#stop} For stopping playback
   * @see {@link AnimatedSprite#loop} For controlling looping behavior
   */
  get playing() {
    return this._playing;
  }
  /**
   * Controls whether the animation automatically updates using the shared ticker.
   * When enabled, the animation will update on each frame. When disabled, you must
   * manually call update() to advance the animation.
   * @example
   * ```ts
   * // Create sprite with auto-update disabled
   * const sprite = new AnimatedSprite({
   *     textures: [],
   *     autoUpdate: false
   * });
   *
   * // Manual update with app ticker
   * app.ticker.add((ticker) => {
   *     sprite.update(ticker);
   * });
   *
   * // Enable auto-update later
   * sprite.autoUpdate = true;
   * ```
   * @default true
   * @see {@link AnimatedSprite#update} For manual animation updates
   * @see {@link Ticker} For the timing system
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
}

export { AnimatedSprite };
//# sourceMappingURL=AnimatedSprite.mjs.map
