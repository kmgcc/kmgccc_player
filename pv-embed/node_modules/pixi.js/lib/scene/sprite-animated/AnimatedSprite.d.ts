import { Texture } from '../../rendering/renderers/shared/texture/Texture';
import { Ticker } from '../../ticker/Ticker';
import { type DestroyOptions } from '../container/destroyTypes';
import { Sprite } from '../sprite/Sprite';
import type { SpriteOptions } from '../sprite/Sprite';
/**
 * A collection of textures or frame objects that can be used to create an `AnimatedSprite`.
 * @see {@link AnimatedSprite}
 * @category scene
 * @standard
 */
export type AnimatedSpriteFrames = Texture[] | FrameObject[];
/**
 * Constructor options used for `AnimatedSprite` instances. Allows configuration of animation
 * playback, speed, and texture frames.
 * @example
 * ```ts
 * // Create a basic animated sprite
 * const sprite = new AnimatedSprite({
 *     textures: [
 *         Texture.from('walk1.png'),
 *         Texture.from('walk2.png'),
 *         Texture.from('walk3.png')
 *     ],
 *     animationSpeed: 0.1,
 *     loop: true
 * });
 *
 * // Create with spritesheet frames and callbacks
 * const sheet = await Assets.load('character.json');
 * const animatedSprite = new AnimatedSprite({
 *     textures: sheet.animations['walk'],
 *     autoPlay: true,
 *     updateAnchor: true,
 *     onComplete: () => console.log('Animation complete'),
 *     onFrameChange: (frame) => console.log('Current frame:', frame),
 *     onLoop: () => console.log('Animation looped')
 * });
 *
 * // Create with custom timing for each frame
 * const customTimingSprite = new AnimatedSprite({
 *     textures: [
 *         { texture: Texture.from('frame1.png'), time: 100 },
 *         { texture: Texture.from('frame2.png'), time: 200 },
 *         { texture: Texture.from('frame3.png'), time: 300 }
 *     ],
 *     autoUpdate: true
 * });
 * ```
 * @see {@link AnimatedSprite} For the main sprite class
 * @see {@link Spritesheet} For loading animations from spritesheets
 * @category scene
 * @standard
 * @noInheritDoc
 */
export interface AnimatedSpriteOptions extends PixiMixins.AnimatedSpriteOptions, Omit<SpriteOptions, 'texture'> {
    /**
     * The speed that the AnimatedSprite will play at. Higher is faster, lower is slower.
     * @example
     * ```ts
     * // Create an AnimatedSprite with a slower animation speed
     * const animation = new AnimatedSprite({
     *     textures: [Texture.from('frame1.png'), Texture.from('frame2.png')],
     *     animationSpeed: 0.5 // Slower animation
     * });
     *
     * // Update the animation speed to make it faster
     * animation.animationSpeed = 2; // Faster animation
     * ```
     * @default 1
     */
    animationSpeed?: number;
    /**
     * Whether to start the animation immediately on creation.
     * If set to `true`, the animation will start playing as soon as the
     * `AnimatedSprite` is created.
     * If set to `false`, you will need to call the `play` method to start the animation.
     * @example
     * ```ts
     * // Create an AnimatedSprite that starts playing immediately
     * const animation = new AnimatedSprite({
     *     textures: [Texture.from('frame1.png'), Texture.from('frame2.png')],
     *     autoPlay: true
     * });
     *
     * // Create an AnimatedSprite that does not start playing immediately
     * const animation = new AnimatedSprite({
     *     textures: [Texture.from('frame1.png'), Texture.from('frame2.png')],
     *     autoPlay: false
     * });
     * animation.play(); // Start the animation manually
     * ```
     * @default false
     */
    autoPlay?: boolean;
    /**
     * Whether to use Ticker.shared to auto update animation time.
     * This is useful for animations that need to be updated every frame.
     * If set to `false`, you will need to manually call the `update` method
     * to update the animation.
     * @example
     * ```ts
     * // Create an AnimatedSprite that does not auto update
     * const animation = new AnimatedSprite({
     *     textures: [Texture.from('frame1.png'), Texture.from('frame2.png')],
     *     autoUpdate: false
     * });
     *
     * // Manually update the animation in your game loop
     * ticker.add((ticker) => {
     *     animation.update(ticker);
     * }
     * ```
     * @default true
     */
    autoUpdate?: boolean;
    /**
     * Whether or not the animation repeats after playing.
     * @default true
     */
    loop?: boolean;
    /**
     * User-assigned function to call when an AnimatedSprite finishes playing.
     * @example
     * ```ts
     * animation.onComplete = () => {
     *     // Finished!
     *     console.log('Animation complete');
     * };
     * ```
     * @default null
     * @see {@link AnimatedSprite#onFrameChange} For the callback when the frame changes
     * @see {@link AnimatedSprite#onLoop} For the callback when the animation loops
     * @see {@link AnimatedSprite#loop} For the loop behavior of the animation
     */
    onComplete?: () => void;
    /**
     * User-assigned function to call when an AnimatedSprite changes which texture is being rendered.
     * @example
     * ```ts
     * animation.onFrameChange = (currentFrame) => {
     *     // Updated!
     *     console.log('Current frame:', currentFrame);
     * };
     * ```
     * @see {@link AnimatedSprite#onComplete} For the callback when the animation finishes
     * @see {@link AnimatedSprite#onLoop} For the callback when the animation loops
     * @default null
     */
    onFrameChange?: (currentFrame: number) => void;
    /**
     * User-assigned function to call when `loop` is true,
     * and an AnimatedSprite is played and loops around to start again.
     * @example
     * ```ts
     * animation.onLoop = () => {
     *     // Looped!
     * };
     * ```
     * @see {@link AnimatedSprite#onComplete} For the callback when the animation finishes
     * @see {@link AnimatedSprite#onFrameChange} For the callback when the frame changes
     * @see {@link AnimatedSprite#loop} For the loop behavior of the animation
     * @default null
     */
    onLoop?: () => void;
    /**
     * An array of {@link Texture} or frame objects that make up the animation.
     * @example
     * ```ts
     * // Create an AnimatedSprite with an array of textures
     * const animation = new AnimatedSprite({
     *     textures: [
     *         Texture.from('frame1.png'),
     *         Texture.from('frame2.png'),
     *         Texture.from('frame3.png')
     *     ]
     * });
     * * // Create an AnimatedSprite with an array of frame objects
     * const animation = new AnimatedSprite({
     *     textures: [
     *         { texture: Texture.from('frame1.png'), time: 100 },
     *         { texture: Texture.from('frame2.png'), time: 200 },
     *         { texture: Texture.from('frame3.png'), time: 300 }
     *     ]
     * });
     * ```
     * @see {@link AnimatedSpriteFrames} For the type of the textures array
     */
    textures: AnimatedSpriteFrames;
    /**
     * Update anchor to [Texture's defaultAnchor]{@link Texture#defaultAnchor} when frame changes.
     *
     * Useful with [sprite sheet animations]{@link Spritesheet#animations} created with tools.
     * Changing anchor for each frame allows to pin sprite origin to certain moving feature
     * of the frame (e.g. left foot).
     * > [!NOTE] Enabling this will override any previously set `anchor` on each frame change.
     * @example
     * ```ts
     * // Create an AnimatedSprite with updateAnchor enabled
     * const animation = new AnimatedSprite({
     *     textures: [Texture.from('frame1.png'), Texture.from('frame2.png')],
     *     updateAnchor: true
     * });
     * ```
     * @see {@link Texture#defaultAnchor} For the default anchor of the texture
     * @default false
     */
    updateAnchor?: boolean;
}
export interface AnimatedSprite extends PixiMixins.AnimatedSprite, Sprite {
}
/**
 * An AnimatedSprite is a simple way to display an animation depicted by a list of textures.
 * @example
 * ```js
 * import { AnimatedSprite, Texture } from 'pixi.js';
 *
 * const alienImages = [
 *     'image_sequence_01.png',
 *     'image_sequence_02.png',
 *     'image_sequence_03.png',
 *     'image_sequence_04.png',
 * ];
 * const textureArray = [];
 *
 * for (let i = 0; i < 4; i++)
 * {
 *     const texture = Texture.from(alienImages[i]);
 *     textureArray.push(texture);
 * }
 *
 * const animatedSprite = new AnimatedSprite(textureArray);
 * ```
 *
 * The more efficient and simpler way to create an animated sprite is using a {@link Spritesheet}
 * containing the animation definitions:
 * @example
 * ```js
 * import { AnimatedSprite, Assets } from 'pixi.js';
 *
 * const sheet = await Assets.load('assets/spritesheet.json');
 * animatedSprite = new AnimatedSprite(sheet.animations['image_sequence']);
 * ```
 * @category scene
 * @standard
 */
export declare class AnimatedSprite extends Sprite {
    /**
     * The speed that the AnimatedSprite will play at. Higher is faster, lower is slower.
     * @example
     * ```ts
     * // Create a sprite with normal speed animation
     * const sprite = new AnimatedSprite({
     *     textures: [
     *         Texture.from('walk1.png'),
     *         Texture.from('walk2.png'),
     *         Texture.from('walk3.png')
     *     ],
     *     animationSpeed: 1 // Default speed
     * });
     *
     * // Slow down the animation
     * sprite.animationSpeed = 0.5;
     *
     * // Speed up the animation
     * sprite.animationSpeed = 2;
     *
     * // Reverse the animation
     * sprite.animationSpeed = -1;
     *
     * // Stop the animation
     * sprite.animationSpeed = 0;
     * ```
     * @default 1
     * @see {@link AnimatedSprite#currentFrame} For the current frame index
     * @see {@link AnimatedSprite#totalFrames} For total number of frames
     */
    animationSpeed: number;
    /**
     * Whether or not the animation repeats after playing.
     * When true, the animation will restart from the beginning after reaching the last frame.
     * When false, the animation will stop on the last frame.
     * @example
     * ```ts
     * // Create a looping animation
     * const sprite = new AnimatedSprite({
     *     textures: [
     *         Texture.from('walk1.png'),
     *         Texture.from('walk2.png'),
     *         Texture.from('walk3.png')
     *     ],
     *     loop: true // Will repeat
     * });
     *
     * // Play animation once
     * sprite.loop = false;
     * sprite.onComplete = () => console.log('Animation finished!');
     * sprite.play();
     *
     * // Toggle looping at runtime
     * sprite.loop = !sprite.loop;
     * ```
     * @default true
     * @see {@link AnimatedSprite#onComplete} Callback when non-looping animation completes
     * @see {@link AnimatedSprite#onLoop} Callback when animation loops
     */
    loop: boolean;
    /**
     * Update anchor to [Texture's defaultAnchor]{@link Texture#defaultAnchor} when frame changes.
     *
     * Useful with [sprite sheet animations]{@link Spritesheet#animations} created with tools.
     * Changing anchor for each frame allows to pin sprite origin to certain moving feature
     * of the frame (e.g. left foot).
     *
     * > [!NOTE] Enabling this will override any previously set `anchor` on each frame change.
     * @default false
     */
    updateAnchor: boolean;
    /**
     * User-assigned function to call when an AnimatedSprite finishes playing.
     *
     * This function is called when the animation reaches the end and stops playing.
     * If the animation is set to loop, this function will not be called.
     * @example
     * ```ts
     * animation.onComplete = () => {
     *     // Finished!
     * };
     * ```
     */
    onComplete?: () => void;
    /**
     * User-assigned function to call when an AnimatedSprite changes which texture is being rendered.
     *
     * This function is called every time the current frame changes during playback.
     * It receives the current frame index as an argument.
     * @example
     * animation.onFrameChange = () => {
     *     // Updated!
     * };
     */
    onFrameChange?: (currentFrame: number) => void;
    /**
     * User-assigned function to call when `loop` is true, and an AnimatedSprite is played and
     * loops around to start again.
     * @example
     * animation.onLoop = () => {
     *     // Looped!
     * };
     */
    onLoop?: () => void;
    private _playing;
    private _textures;
    private _durations;
    /**
     * `true` uses Ticker.shared to auto update animation time.
     * @default true
     */
    private _autoUpdate;
    /**
     * `true` if the instance is currently connected to Ticker.shared to auto update animation time.
     * @default false
     */
    private _isConnectedToTicker;
    /** Elapsed time since animation has been started, used internally to display current texture. */
    private _currentTime;
    /** The texture index that was displayed last time. */
    private _previousFrame;
    /**
     * @param frames - Collection of textures or frames to use.
     * @param autoUpdate - Whether to use Ticker.shared to auto update animation time.
     */
    constructor(frames: AnimatedSpriteFrames, autoUpdate?: boolean);
    /**
     * @param options - The options for the AnimatedSprite.
     */
    constructor(options: AnimatedSpriteOptions);
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
    stop(): void;
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
    play(): void;
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
    gotoAndStop(frameNumber: number): void;
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
    gotoAndPlay(frameNumber: number): void;
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
    update(ticker: Ticker): void;
    /** Updates the displayed texture to match the current frame index. */
    private _updateTexture;
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
    destroy(options?: DestroyOptions): void;
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
    static fromFrames(frames: string[]): AnimatedSprite;
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
    static fromImages(images: string[]): AnimatedSprite;
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
    get totalFrames(): number;
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
    get textures(): AnimatedSpriteFrames;
    set textures(value: AnimatedSpriteFrames);
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
    get currentFrame(): number;
    set currentFrame(value: number);
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
    get playing(): boolean;
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
    get autoUpdate(): boolean;
    set autoUpdate(value: boolean);
}
/**
 * A reference to a frame in an {@link AnimatedSprite}
 * @category scene
 * @advanced
 */
export interface FrameObject {
    /** The {@link Texture} of the frame. */
    texture: Texture;
    /** The duration of the frame, in milliseconds. */
    time: number;
}
