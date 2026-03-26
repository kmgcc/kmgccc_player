import { Sprite, type SpriteOptions } from '../scene/sprite/Sprite';
import { Ticker } from '../ticker/Ticker';
import { GifSource } from './GifSource';
import type { SCALE_MODE } from '../rendering/renderers/shared/texture/const';
/**
 * Configuration options for creating a GifSprite instance.
 *
 * These options control both the visual appearance and playback behavior
 * of animated GIFs.
 * @example Minimal Usage
 * ```ts
 * import { Assets } from 'pixi.js';
 * import { GifSprite } from 'pixi.js/gif';
 *
 * // Simple usage, minimal options
 * const source = await Assets.load('animation.gif');
 * const animation = new GifSprite(source);
 * ```
 * @example Advanced Options
 * ```ts
 * import { Assets } from 'pixi.js';
 * import { GifSprite } from 'pixi.js/gif';
 *
 * // Advanced usage with options
 * const source = await Assets.load({
 *   src: 'animation.gif',
 *   data: {
 *     scaleMode: 'nearest'  // Pixelated scaling
 *   }
 * });
 *
 * const animation = new GifSprite({
 *   source,                 // GIF data source
 *   animationSpeed: 1.5,    // 50% faster than normal
 *   loop: true,             // Loop the animation
 *   autoPlay: true,         // Start playing immediately
 *   onComplete() {          // Called when non-looping animation ends
 *     console.log('Animation complete!');
 *   }
 * });
 * ```
 * @category gif
 * @standard
 */
interface GifSpriteOptions extends Omit<SpriteOptions, 'texture'> {
    /**
     * Source containing the GIF frame and animation data
     * @see {@link GifSource}
     * @example
     * ```ts
     * const source = await Assets.load('animation.gif');
     * const animation = new GifSprite({ source });
     * ```
     */
    source: GifSource;
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
    autoPlay?: boolean;
    /**
     * This is not implemented and you should, instead, use `scaleMode`
     * when loading the Asset as an option for the UnresolvedAsset's `data`.
     * @type {SCALE_MODE}
     * @default 'linear'
     * @deprecated since 8.13.0
     */
    scaleMode?: SCALE_MODE;
    /**
     * Whether to loop the animation.
     * If `false`, the animation will stop after the last frame.
     * @default true
     * @example
     * ```ts
     * const animation = new GifSprite({ source, loop: false });
     * ```
     */
    loop?: boolean;
    /**
     * Animation playback speed multiplier.
     * Higher values speed up the animation, lower values slow it down.
     * @default 1
     * @example
     * ```ts
     * const animation = new GifSprite({ source, animationSpeed: 2 }); // 2x speed
     * ```
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    animationSpeed?: number;
    /**
     * Whether to auto-update animation via shared ticker.
     * Set to `false` to manage updates yourself.
     * @default true
     * @example
     * ```ts
     * const animation = new GifSprite({ source, autoUpdate: false });
     * // Manage updates manually:
     * app.ticker.add((ticker) => {
     *     animation.update(ticker);
     * });
     * ```
     */
    autoUpdate?: boolean;
    /**
     * Callback when non-looping animation completes.
     * This is only called if `loop` is set to `false`.
     * If `loop` is `true`, use {@link GifSprite.onLoop} instead.
     * @default null
     * @example
     * ```ts
     * const animation = new GifSprite({
     *     source,
     *     onComplete: () => {
     *         console.log('Animation finished!');
     *     }
     * });
     * ```
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    onComplete?: null | (() => void);
    /**
     * Callback when looping animation completes a loop.
     * @default null
     * @example
     * ```ts
     * const animation = new GifSprite({
     *     source,
     *     onLoop: () => {
     *         console.log('Animation looped!');
     *     }
     * });
     * ```
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    onLoop?: null | (() => void);
    /**
     * Callback when animation frame changes.
     * This is called every time the current frame changes,
     * allowing you to respond to frame changes in real-time.
     * @default null
     * @example
     * ```ts
     * const animation = new GifSprite({
     *     source,
     *     onFrameChange: (currentFrame) => {
     *         console.log(`Current frame: ${currentFrame}`);
     *     }
     * });
     * ```
     * @see {@link GifSprite.currentFrame}
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    onFrameChange?: null | ((currentFrame: number) => void);
    /**
     * Fallback FPS if GIF contains no timing information
     * @default 30
     * @example
     * ```ts
     * const animation = new GifSprite({
     *     source,
     *     fps: 24 // Use 24 FPS if GIF timing is missing
     * });
     * ```
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     * @see {@link GifSprite.update}
     */
    fps?: number;
}
/**
 * Runtime object for playing animated GIFs with advanced playback control.
 *
 * Features:
 * - Play, pause, and seek controls
 * - Adjustable animation speed
 * - Loop control
 * - Frame change callbacks
 * - Auto-updating via shared ticker
 *
 * This class extends Sprite and provides similar functionality to AnimatedSprite,
 * but specifically optimized for GIF playback.
 * @example
 * ```ts
 * import { GifSprite, Assets } from 'pixi.js';
 *
 * // Load and create a GIF sprite
 * const source = await Assets.load('animation.gif');
 * const animation = new GifSprite({
 *     source,
 *     animationSpeed: 1,
 *     loop: true,
 *     autoPlay: true
 * });
 *
 * // Add to stage
 * app.stage.addChild(animation);
 *
 * // Control playback
 * animation.play();
 * animation.stop();
 * animation.currentFrame = 5; // Jump to frame
 * ```
 * @category gif
 * @see Thanks to {@link https://github.com/matt-way/gifuct-js/ gifuct-js}
 * @standard
 */
declare class GifSprite extends Sprite {
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
    static defaultOptions: Omit<GifSpriteOptions, 'source'>;
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
    animationSpeed: number;
    /**
     * Whether to loop the animation.
     * If `false`, the animation will stop after the last frame.
     * @default true
     * @example
     * ```ts
     * const animation = new GifSprite({ source, loop: false });
     * ```
     */
    loop: boolean;
    /**
     * Callback when non-looping animation completes.
     * This is only called if `loop` is set to `false`.
     * If `loop` is `true`, use {@link GifSprite.onLoop} instead.
     * @default null
     * @example
     * ```ts
     * const animation = new GifSprite({
     *     source,
     *     onComplete: () => {
     *         console.log('Animation finished!');
     *     }
     * });
     * ```
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    onComplete?: () => void;
    /**
     * Callback when animation frame changes.
     * This is called every time the current frame changes,
     * allowing you to respond to frame changes in real-time.
     * @default null
     * @example
     * ```ts
     * const animation = new GifSprite({
     *     source,
     *     onFrameChange: (currentFrame) => {
     *         console.log(`Current frame: ${currentFrame}`);
     *     }
     * });
     * ```
     * @see {@link GifSprite.currentFrame}
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    onFrameChange?: (currentFrame: number) => void;
    /**
     * Callback when looping animation completes a loop.
     * If `loop` is `false`, this will not be called.
     * @default null
     * @example
     * ```ts
     * const animation = new GifSprite({
     *     source,
     *     onLoop: () => {
     *         console.log('Animation looped!');
     *     }
     * });
     * ```
     * @see {@link GifSprite.play}
     * @see {@link GifSprite.stop}
     */
    onLoop?: () => void;
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
    readonly duration: number;
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
    readonly autoPlay: boolean;
    /** Collection of frame to render. */
    private _source;
    /**
     * Dirty means the image needs to be redrawn. Set to `true` to force redraw.
     * @advanced
     */
    dirty: boolean;
    /** The current frame number (zero-based index). */
    private _currentFrame;
    /** `true` uses {@link Ticker.shared} to auto update animation time.*/
    private _autoUpdate;
    /** `true` if the instance is currently connected to {@link Ticker.shared} to auto update animation time. */
    private _isConnectedToTicker;
    /** If animation is currently playing. */
    private _playing;
    /** Current playback position in milliseconds. */
    private _currentTime;
    /**
     * @param source - Source, default options will be used.
     */
    constructor(source: GifSource);
    /**
     * @param options - Options for the GifSprite
     */
    constructor(options: GifSpriteOptions);
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
    stop(): void;
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
    play(): void;
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
    get progress(): number;
    /** `true` if the current animation is playing */
    get playing(): boolean;
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
    update(ticker: Ticker): void;
    /** Redraw the current frame, is necessary for the animation to work when */
    private _updateFrame;
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
    get autoUpdate(): boolean;
    set autoUpdate(value: boolean);
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
    get currentFrame(): number;
    set currentFrame(value: number);
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
    get source(): GifSource;
    /**
     * Internally handle updating the frame index
     * @param value
     */
    private _updateFrameIndex;
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
    get totalFrames(): number;
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
    destroy(destroyData?: boolean): void;
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
    clone(): GifSprite;
}
export { GifSprite };
export type { GifSpriteOptions };
